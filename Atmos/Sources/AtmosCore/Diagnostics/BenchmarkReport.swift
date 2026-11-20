// TESTING BEGIN: immutable, local-only trial export. No request headers or keys.
import Foundation

public struct BenchmarkReport: Encodable, Sendable {
    public struct Stage: Encodable, Sendable {
        public let name: String
        public let offsetSeconds: Double
        public let durationSeconds: Double
        public let outcome: String
    }
    public struct Action: Encodable, Sendable {
        public let id: UUID
        public let recordedAt: Date
        public let goal: String
        public let route: String
        public let description: String
        public let payloadJSON: String
        public let dispatchStatus: String
        public let detail: String?
    }
    public struct Usage: Encodable, Sendable {
        public let attemptedRequests: Int
        public let reportedInputTokens: Int
        public let reportedOutputTokens: Int
        public let estimatedUSD: Double
    }
    public let schemaVersion = 1
    public let id: UUID
    public let recordedAt: Date
    public let command: String
    public let behavior: String
    public let configuration: BenchmarkConfiguration
    public let outcome: String
    public let cutoffReason: BenchmarkStopReason?
    public let startingContextEntryCount: Int
    public let contextPolicy = "Every trial starts with the command context saved when benchmark mode was enabled. Trial commands are removed from model context afterward; the original user history is restored. Action logs remain available for diagnosis."
    public let totalSeconds: Double
    public let firstInputAttemptSeconds: Double?
    public let stages: [Stage]
    public let actions: [Action]
    public let routes: [String]
    public let usage: Usage
    public let timingReport: String
    public let limitation = "Outcome is Atmos's reported result, not independent visual verification. First input is a dispatch attempt. Usage includes only returned usage and may omit server work after cancellation; cost is an estimate. Overlapping stages are not additive. Any timing omissions are stated in timingReport."

    public init(timing: PipelineTiming, command: String, behavior: String,
                configuration: BenchmarkConfiguration, actions: [ActionHistory.Entry], firstActionIndex: Int, routes: [String],
                before: DemoBudget, after: DemoBudget,
                cutoffReason: BenchmarkStopReason? = nil, startingContextEntryCount: Int = 0) {
        let snapshot = timing.snapshot
        precondition(snapshot.outcome != .running, "Only frozen terminal traces can be exported")
        id = timing.id
        recordedAt = Date()
        self.command = command
        self.behavior = behavior
        self.configuration = configuration
        outcome = snapshot.outcome.rawValue
        self.cutoffReason = cutoffReason
        self.startingContextEntryCount = startingContextEntryCount
        totalSeconds = snapshot.totalDuration
        firstInputAttemptSeconds = snapshot.firstInputDuration
        stages = snapshot.stages.map {
            Stage(name: $0.name, offsetSeconds: $0.offset, durationSeconds: $0.duration, outcome: $0.outcome.rawValue)
        }
        // Never export earlier task payloads. Invalid ownership bounds fail closed.
        let owned = (0...actions.count).contains(firstActionIndex) ? Array(actions.dropFirst(firstActionIndex)) : []
        self.actions = owned.map {
            Action(id: $0.id, recordedAt: $0.recordedAt, goal: $0.goal, route: $0.source,
                   description: $0.description, payloadJSON: $0.payloadJSON,
                   dispatchStatus: $0.status.rawValue, detail: $0.detail)
        }
        self.routes = routes
        usage = Usage(attemptedRequests: max(0, after.requests - before.requests),
                      reportedInputTokens: max(0, after.inputTokens - before.inputTokens),
                      reportedOutputTokens: max(0, after.outputTokens - before.outputTokens),
                      estimatedUSD: max(0, after.estimatedUSD - before.estimatedUSD))
        timingReport = timing.report
    }
}
// TESTING END
