import Foundation

/// Audio-time assembly and endpoint decisions, independent of Apple's engines.
/// Volatile text is preview-only; a candidate must remain current until a separate
/// final result stream has completed before its command can be committed.
public struct SpeechTranscriptState {
    public struct Segment: Equatable, Sendable {
        public let start: TimeInterval
        public let end: TimeInterval
        public let text: String
        public init(start: TimeInterval, end: TimeInterval, text: String) {
            self.start = start; self.end = end; self.text = text
        }
    }
    public struct Candidate: Equatable, Sendable {
        public let id: UUID
        public let through: TimeInterval
        public let startedAt: TimeInterval
    }

    public private(set) var segments: [Segment] = []
    public private(set) var consumedThrough: TimeInterval = 0
    public private(set) var audioEnd: TimeInterval = 0
    public private(set) var lastSpeechAt: TimeInterval = 0
    public private(set) var lastResultAt: TimeInterval = 0
    public private(set) var convertedCaptureAt: TimeInterval?
    public private(set) var candidate: Candidate?
    public var text: String { segments.sorted { $0.start < $1.start }.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines) }
    public var firstTextStart: TimeInterval? { segments.map(\.start).min() }

    public init() {}

    /// Returns true when continued speech invalidates an in-flight final pass.
    @discardableResult
    public mutating func observeAudio(end: TimeInterval, lastSpeechAt: TimeInterval, convertedCaptureAt: TimeInterval? = nil) -> Bool {
        audioEnd = max(audioEnd, end)
        if let convertedCaptureAt { self.convertedCaptureAt = max(self.convertedCaptureAt ?? 0, convertedCaptureAt) }
        self.lastSpeechAt = max(self.lastSpeechAt, lastSpeechAt)
        guard let candidate, lastSpeechAt > candidate.startedAt else { return false }
        self.candidate = nil
        return true
    }

    /// A new result replaces its audio range, never appends an old hypothesis.
    @discardableResult
    public mutating func replace(start: TimeInterval, end: TimeInterval, with replacements: [Segment], at time: TimeInterval) -> Bool {
        guard start.isFinite, end.isFinite, end > consumedThrough else { return false }
        let updated = segments.filter { $0.end <= start || $0.start >= end }
            + replacements.filter { $0.end > consumedThrough && $0.start >= consumedThrough && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sorted = updated.sorted { $0.start < $1.start }
        guard sorted != segments else { return false }
        segments = sorted
        lastResultAt = time
        let invalidated = candidate != nil
        candidate = nil
        return invalidated
    }

    public mutating func beginFinalization(at time: TimeInterval, silenceDuration: TimeInterval = 1.0, latestCaptureAt: TimeInterval? = nil) -> Candidate? {
        guard candidate == nil, !text.isEmpty, audioEnd > consumedThrough,
              audioIsCaughtUp(at: time, latestCaptureAt: latestCaptureAt),
              time - max(lastSpeechAt, lastResultAt) >= silenceDuration else { return nil }
        let next = Candidate(id: UUID(), through: audioEnd, startedAt: time)
        candidate = next
        return next
    }

    public func isCurrent(_ candidate: Candidate) -> Bool { self.candidate == candidate }

    public func audioIsCaughtUp(at time: TimeInterval, latestCaptureAt: TimeInterval?) -> Bool {
        guard let latestCaptureAt else { return true }
        guard let convertedCaptureAt else { return false }
        return time - convertedCaptureAt <= 0.25 && latestCaptureAt - convertedCaptureAt <= 0.25
    }

    public mutating func invalidateFinalization() { candidate = nil }

    @discardableResult
    public mutating func commit(_ candidate: Candidate) -> Bool {
        guard isCurrent(candidate) else { return false }
        discard(through: candidate.through)
        return true
    }

    public mutating func discard(through time: TimeInterval) {
        consumedThrough = max(consumedThrough, time)
        segments.removeAll { $0.start < consumedThrough }
        candidate = nil
    }
}
