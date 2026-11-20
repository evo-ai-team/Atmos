// TESTING BEGIN: removable, opt-in live benchmark limits; no networking or input.
import Foundation

public enum BenchmarkStopReason: String, Codable, Sendable {
    case deadline, batchLimit, requestLimit, manualStop, disabled
}

public struct BenchmarkConfiguration: Codable, Equatable, Sendable {
    public let durationSeconds: Double
    public let maximumActionBatches: Int
    public let maximumRequests: Int
    public init(durationSeconds: Double = 30, maximumActionBatches: Int = 6, maximumRequests: Int = 30) {
        self.durationSeconds = durationSeconds.isFinite ? min(30, max(1, durationSeconds)) : 30
        self.maximumActionBatches = min(6, max(1, maximumActionBatches))
        self.maximumRequests = min(30, max(1, maximumRequests))
    }
}

/// Session request limits survive individual trials. The caller must reserve
/// before sending, and must end the exact trial before accepting another one.
public struct BenchmarkSession: Sendable {
    public enum Failure: LocalizedError, Equatable {
        case alreadyRunning, staleTrial, requestLimit, batchLimit, deadline
        public var stopReason: BenchmarkStopReason? {
            switch self {
            case .deadline: return .deadline
            case .batchLimit: return .batchLimit
            case .requestLimit: return .requestLimit
            case .alreadyRunning, .staleTrial: return nil
            }
        }
        public var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "TESTING: another benchmark trial is still running."
            case .staleTrial: return "TESTING: this operation no longer belongs to the current trial."
            case .requestLimit: return "TESTING: the benchmark session request limit was reached before sending another request."
            case .batchLimit: return "TESTING: the trial action-batch limit was reached before dispatching another action batch."
            case .deadline: return "TESTING: the benchmark trial deadline was reached."
            }
        }
    }
    public let configuration: BenchmarkConfiguration
    public private(set) var requestCount = 0
    public private(set) var trialID: UUID?
    private var deadline: Double?
    public init(configuration: BenchmarkConfiguration = .init()) { self.configuration = configuration }

    public mutating func begin(id: UUID, now: Double) throws {
        guard trialID == nil else { throw Failure.alreadyRunning }
        guard requestCount < configuration.maximumRequests else { throw Failure.requestLimit }
        trialID = id
        deadline = now + configuration.durationSeconds
    }
    public func check(id: UUID, now: Double, completedBatches: Int = 0) throws {
        guard id == trialID, let deadline else { throw Failure.staleTrial }
        guard now < deadline else { throw Failure.deadline }
        guard completedBatches < configuration.maximumActionBatches else { throw Failure.batchLimit }
    }
    public mutating func reserveRequest(id: UUID, now: Double) throws {
        try check(id: id, now: now)
        guard requestCount < configuration.maximumRequests else { throw Failure.requestLimit }
        requestCount += 1
    }
    @discardableResult public mutating func end(id: UUID) -> Bool {
        guard trialID == id else { return false }
        trialID = nil
        deadline = nil
        return true
    }
}
// TESTING END
