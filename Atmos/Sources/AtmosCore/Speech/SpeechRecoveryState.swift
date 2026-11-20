import Foundation

/// Bounded recovery belongs to a microphone-enable generation. A user pause
/// invalidates every pending attempt, including one already awaiting startup.
public struct SpeechRecoveryState {
    public struct Attempt: Equatable, Sendable {
        public let generation: UUID
        public let delay: TimeInterval
    }
    public private(set) var isEnabled = false
    public var sessionID: UUID { generation }
    private var generation = UUID()
    private var failures: [TimeInterval] = []
    public init() {}

    public mutating func enable() {
        generation = UUID()
        failures = []
        isEnabled = true
    }

    public mutating func disable() {
        generation = UUID()
        failures = []
        isEnabled = false
    }

    public mutating func nextAttempt(at time: TimeInterval) -> Attempt? {
        guard isEnabled else { return nil }
        failures.removeAll { time - $0 >= 60 }
        guard failures.count < 3 else { return nil }
        let delay = [0.3, 0.8, 1.5][failures.count]
        failures.append(time)
        return Attempt(generation: generation, delay: delay)
    }

    public func isCurrent(_ attempt: Attempt) -> Bool {
        isEnabled && attempt.generation == generation
    }
}
