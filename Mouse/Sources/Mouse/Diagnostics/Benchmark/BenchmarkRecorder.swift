// TESTING BEGIN: removable live-benchmark recorder, instantiated only on opt-in.
import AppKit
#if SWIFT_PACKAGE
import MouseCore
#endif

@MainActor final class BenchmarkRecorder {
    struct Trial {
        let timing: PipelineTiming
        let command: String
        let behavior: String
        let before: DemoBudget
        let firstActionIndex: Int
        let startingContextEntryCount: Int
        var firstObservation: ScreenObservation?
        var latestObservation: ScreenObservation?
        var cutoffReason: BenchmarkStopReason?
        var routes: [String] = []
    }
    private(set) var session = BenchmarkSession()
    private(set) var trial: Trial?
    private var monitor: Task<Void, Never>?
    let directory: URL
    var isRunning: Bool { trial != nil }

    init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func begin(timing: PipelineTiming, command: String, behavior: String, budget: DemoBudget, firstActionIndex: Int,
               startingContextEntryCount: Int,
               onDeadline: @escaping @MainActor () -> Void,
               onFinished: @escaping @MainActor () async -> Void) throws {
        try session.begin(id: timing.id, now: ProcessInfo.processInfo.systemUptime)
        trial = Trial(timing: timing, command: command, behavior: behavior, before: budget,
                      firstActionIndex: firstActionIndex, startingContextEntryCount: startingContextEntryCount)
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.trial?.timing.id == timing.id else { return }
                if timing.snapshot.outcome != .running { await onFinished(); return }
                do { try self.session.check(id: timing.id, now: ProcessInfo.processInfo.systemUptime) }
                catch {
                    self.noteStop(.deadline)
                    onDeadline()
                    timing.finish(.cancelled)
                    await onFinished()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
    }

    func captureFirst(_ observation: ScreenObservation, timing: PipelineTiming) {
        guard trial?.timing.id == timing.id, trial?.firstObservation == nil else { return }
        trial?.firstObservation = observation
        trial?.latestObservation = observation
    }
    func captureLatest(_ observation: ScreenObservation, timing: PipelineTiming) {
        guard trial?.timing.id == timing.id, timing.snapshot.outcome == .running else { return }
        trial?.latestObservation = observation
    }
    func noteStop(_ reason: BenchmarkStopReason) {
        guard let current = trial, current.cutoffReason == nil,
              current.timing.snapshot.outcome == .running else { return }
        trial?.cutoffReason = reason
        current.timing.annotate("TESTING: benchmark cutoff = \(reason.rawValue)")
    }
    func reserveRequest(timing: PipelineTiming) throws {
        do { try session.reserveRequest(id: timing.id, now: ProcessInfo.processInfo.systemUptime) }
        catch {
            if let reason = (error as? BenchmarkSession.Failure)?.stopReason { noteStop(reason) }
            throw error
        }
    }
    func checkBatch(timing: PipelineTiming, completed: Int) throws {
        do { try session.check(id: timing.id, now: ProcessInfo.processInfo.systemUptime, completedBatches: completed) }
        catch {
            if let reason = (error as? BenchmarkSession.Failure)?.stopReason { noteStop(reason) }
            throw error
        }
    }
    func recordRoute(_ route: String, timing: PipelineTiming) {
        guard trial?.timing.id == timing.id else { return }
        trial?.routes.append(route)
    }

    /// Caller drains cancelled input cleanup before freezing action/usage copies.
    /// All disk work follows the immutable timing boundary. Partial export errors
    /// are surfaced, and a unique directory prevents overwriting earlier trials.
    func finish(actions: [ActionHistory.Entry], budget: DemoBudget) throws -> URL? {
        guard let trial, trial.timing.snapshot.outcome != .running else { return nil }
        defer {
            _ = session.end(id: trial.timing.id)
            self.trial = nil
            monitor = nil
        }
        let report = BenchmarkReport(timing: trial.timing, command: trial.command, behavior: trial.behavior,
                                     configuration: session.configuration,
                                     actions: actions, firstActionIndex: trial.firstActionIndex, routes: trial.routes,
                                     before: trial.before, after: budget, cutoffReason: trial.cutoffReason,
                                     startingContextEntryCount: trial.startingContextEntryCount)
        let target = directory.appendingPathComponent("TESTING-" + trial.timing.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let reportURL = target.appendingPathComponent("report.json")
        try encoder.encode(report).write(to: reportURL, options: .atomic)
        try Data(report.timingReport.utf8).write(to: target.appendingPathComponent("timing.txt"), options: .atomic)
        try exportObservation(trial.firstObservation, prefix: "first", to: target, encoder: encoder)
        // This is the last frame already observed by the real pipeline. During
        // cancellation it may precede the final input; do not call it final proof.
        try exportObservation(trial.latestObservation, prefix: "last-observed", to: target, encoder: encoder)
        return reportURL
    }

    private func exportObservation(_ observation: ScreenObservation?, prefix: String,
                                   to target: URL, encoder: JSONEncoder) throws {
        guard let observation else { return }
        let frame = observation.frame
        try frame.data.write(to: target.appendingPathComponent(prefix + "-screen.jpg"), options: .atomic)
        try encoder.encode(observation.accessibility).write(to: target.appendingPathComponent(prefix + "-ax.json"), options: .atomic)
        let geometry: [String: Any] = [
            "imageWidth": frame.width, "imageHeight": frame.height,
            "originX": frame.originX, "originY": frame.originY,
            "pointWidth": frame.pointWidth, "pointHeight": frame.pointHeight,
            "displayID": frame.displayID, "processID": observation.processID,
            "capturedAtUptime": observation.capturedAt,
            "note": "Existing pipeline capture; may precede later input or cancellation. Completion is model-declared."
        ]
        try JSONSerialization.data(withJSONObject: geometry, options: [.prettyPrinted, .sortedKeys])
            .write(to: target.appendingPathComponent(prefix + "-frame.json"), options: .atomic)
    }
}
// TESTING END
