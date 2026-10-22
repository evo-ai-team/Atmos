import Foundation

/// One command's timing trace. Labels describe stages only: callers must not put
/// commands, screen content, credentials, or typed text in them.
///
/// All timestamps use system uptime rather than wall time. Parallel capture and
/// transcription can overlap, so the total comes from the trace's boundaries,
/// never from adding stage durations. A lock protects only small in-memory edits;
/// recording a stage never performs I/O or waits for another pipeline operation.
public final class PipelineTiming: @unchecked Sendable {
    public enum Origin: String, Sendable { case speech, typed, continued }
    public enum Outcome: String, Sendable {
        case running, succeeded, failed, cancelled, ignored, superseded, paused
    }

    /// An opaque token belonging to the trace that created it. Ending the same
    /// token twice, or passing it to another trace, has no effect.
    public struct Span: Sendable {
        fileprivate let traceID: UUID
        fileprivate let recordID: UUID
    }

    private struct Record {
        let id: UUID
        let name: String
        let start: TimeInterval
        var order = 0
        var end: TimeInterval?
        var outcome: Outcome
    }

    private struct Annotation {
        let message: String
        let at: TimeInterval
        let order: Int
    }

    private static let recordLimit = 256
    // Metadata cannot crowd out stage timings. A separate, small cap also keeps
    // transport diagnostics bounded when a command makes many requests.
    private static let annotationLimit = 64
    private static let annotationCharacterLimit = 1024
    public let id = UUID()
    private let origin: Origin
    private let startedAt: TimeInterval
    private let clock: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var lastObservedAt: TimeInterval
    private var endedAt: TimeInterval?
    private var outcome: Outcome = .running
    private var firstInputAt: TimeInterval?
    private var records: [Record] = []
    private var droppedRecords = 0
    private var annotations: [Annotation] = []
    private var droppedAnnotations = 0
    private var completedReport: String?

    public init(
        origin: Origin,
        startedAt: TimeInterval? = nil,
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        let sample = clock()
        let now = Self.validTimestamp(sample) ? sample : 0
        self.origin = origin
        self.clock = clock
        self.startedAt = startedAt.flatMap { Self.validTimestamp($0) ? min($0, now) : nil } ?? now
        lastObservedAt = now
    }

    @discardableResult
    public func begin(_ name: String, at: TimeInterval? = nil) -> Span {
        let sample = clock()
        let span = Span(traceID: id, recordID: UUID())
        lock.lock()
        defer { lock.unlock() }
        guard endedAt == nil else { return span }
        let now = observe(sample)
        append(Record(id: span.recordID, name: name, start: bounded(at, now: now), end: nil, outcome: .running))
        return span
    }

    public func end(_ span: Span?, outcome: Outcome = .succeeded) {
        guard let span, span.traceID == id, outcome != .running else { return }
        let sample = clock()
        lock.lock()
        defer { lock.unlock() }
        guard endedAt == nil,
              let index = records.firstIndex(where: { $0.id == span.recordID }),
              records[index].end == nil else { return }
        records[index].end = observe(sample)
        records[index].outcome = outcome
    }

    /// Add an interval measured elsewhere, using the same uptime clock. This is
    /// useful for callbacks that report speech activity after it has happened.
    public func record(
        _ name: String,
        from: TimeInterval,
        to: TimeInterval? = nil,
        outcome: Outcome = .succeeded
    ) {
        let sample = clock()
        lock.lock()
        defer { lock.unlock() }
        guard endedAt == nil else { return }
        let now = observe(sample)
        let start = bounded(from, now: now)
        let end = max(start, bounded(to, now: now))
        append(Record(id: UUID(), name: name, start: start, end: end,
                      outcome: outcome == .running ? .succeeded : outcome))
    }

    public func mark(_ name: String) {
        let sample = clock()
        lock.lock()
        defer { lock.unlock() }
        guard endedAt == nil else { return }
        let now = observe(sample)
        append(Record(id: UUID(), name: name, start: now, end: now, outcome: .succeeded))
    }

    /// Attach transport metadata, such as byte counts, request IDs, or provider-
    /// reported processing time. The offset is when we learned the metadata; it
    /// is not a measured interval. Callers must supply safe diagnostic metadata
    /// only, never request bodies, command text, screen content, or credentials.
    public func annotate(_ message: String) {
        let sample = clock()
        // Keep metadata on one bounded line. Formatting happens outside the lock.
        let line = String(message.prefix(Self.annotationCharacterLimit))
            .components(separatedBy: .newlines).joined(separator: " ")
        lock.lock()
        defer { lock.unlock() }
        guard endedAt == nil else { return }
        let now = observe(sample)
        guard annotations.count < Self.annotationLimit else {
            if droppedAnnotations < Int.max { droppedAnnotations += 1 }
            return
        }
        annotations.append(Annotation(message: line, at: now, order: records.count + annotations.count))
    }

    /// Call immediately before the first real input event or AX action attempt.
    /// This measures user-visible dispatch latency, not a verified UI result.
    public func markFirstInput() {
        let sample = clock()
        lock.lock()
        defer { lock.unlock() }
        guard endedAt == nil, firstInputAt == nil else { return }
        firstInputAt = observe(sample)
    }

    /// Freeze the trace and close outstanding spans. Delayed callbacks from old
    /// requests cannot rewrite a completed command's diagnostic evidence.
    public func finish(_ outcome: Outcome) {
        guard outcome != .running else { return }
        let sample = clock()
        lock.lock()
        defer { lock.unlock() }
        guard endedAt == nil else { return }
        let now = observe(sample)
        endedAt = now
        self.outcome = outcome
        for index in records.indices where records[index].end == nil {
            records[index].end = now
            records[index].outcome = outcome
        }
    }

    /// A copyable snapshot, including elapsed durations for work still running.
    public var report: String {
        let sample = clock()
        lock.lock()
        if let completedReport {
            lock.unlock()
            return completedReport
        }
        let now = endedAt ?? observe(sample)
        let snapshot = (outcome: outcome, firstInputAt: firstInputAt, records: records,
                        droppedRecords: droppedRecords, annotations: annotations,
                        droppedAnnotations: droppedAnnotations)
        let isFinished = endedAt != nil
        lock.unlock()

        var lines = [
            "Pipeline timing · \(origin.rawValue) · \(id.uuidString.prefix(8)) · \(snapshot.outcome.rawValue)",
            "Total elapsed: \(Self.milliseconds(now - startedAt))",
            snapshot.firstInputAt.map { "First input attempt: \(Self.milliseconds($0 - startedAt)) (dispatch attempt, not verified success)" }
                ?? "First input attempt: none",
            "Stages (start offset · duration · outcome):"
        ]
        var entries: [(at: TimeInterval, order: Int, line: String)] = snapshot.records.map { record in
            let duration = (record.end ?? now) - record.start
            return (record.start, record.order,
                    "+\(Self.milliseconds(record.start - startedAt)) · \(Self.milliseconds(duration)) · \(record.outcome.rawValue) · \(record.name)")
        }
        entries += snapshot.annotations.map { annotation in
            (annotation.at, annotation.order,
             "@+\(Self.milliseconds(annotation.at - startedAt)) · metadata · \(annotation.message)")
        }
        entries.sort { $0.at == $1.at ? $0.order < $1.order : $0.at < $1.at }
        lines.append(contentsOf: entries.map(\.line))
        if snapshot.droppedRecords > 0 {
            lines.append("\(snapshot.droppedRecords) additional stage records omitted (limit \(Self.recordLimit)).")
        }
        if snapshot.droppedAnnotations > 0 {
            lines.append("\(snapshot.droppedAnnotations) additional metadata annotations omitted (limit \(Self.annotationLimit)).")
        }
        if !snapshot.annotations.isEmpty {
            lines.append("Metadata offsets show when observations were recorded, not measured stage intervals.")
        }
        lines.append("Overlapping stages are not additive; total elapsed is measured independently.")
        let report = lines.joined(separator: "\n")
        if isFinished {
            // Completed traces cannot change. Cache their formatted text so live
            // diagnostics refresh only pays formatting costs for running work.
            // Formatting remains outside the lock used by pipeline callbacks.
            lock.lock()
            completedReport = report
            lock.unlock()
        }
        return report
    }

    // The helpers below run with the lock held. Explicit historical timestamps
    // may precede the latest observation, but never the trace's own start.
    private func observe(_ sample: TimeInterval) -> TimeInterval {
        if Self.validTimestamp(sample) { lastObservedAt = max(lastObservedAt, sample) }
        return lastObservedAt
    }

    private func bounded(_ timestamp: TimeInterval?, now: TimeInterval) -> TimeInterval {
        guard let timestamp, Self.validTimestamp(timestamp) else { return now }
        return min(now, max(startedAt, timestamp))
    }

    private func append(_ record: Record) {
        guard records.count < Self.recordLimit else {
            if droppedRecords < Int.max { droppedRecords += 1 }
            return
        }
        var ordered = record
        ordered.order = records.count + annotations.count
        records.append(ordered)
    }

    private static func validTimestamp(_ timestamp: TimeInterval) -> Bool {
        timestamp.isFinite && timestamp >= 0
    }

    private static func milliseconds(_ seconds: TimeInterval) -> String {
        // Saturating before multiplication also makes adversarial test clocks
        // safe; ordinary system-uptime values are many orders of magnitude lower.
        let milliseconds = min(max(0, seconds), Double.greatestFiniteMagnitude / 1000) * 1000
        return String(format: "%.1f ms", locale: Locale(identifier: "en_US_POSIX"), milliseconds)
    }
}
