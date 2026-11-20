import Foundation

/// Tracks captured audio that recognition has not consumed yet. This keeps idle
/// transcript cleanup from racing a pending utterance; it does not pause desktop
/// actions. Only a command accepted by speech screening can interrupt execution.
public struct SpeechActivityGate {
    private var consumedSpeechAt: TimeInterval
    private var lastNotifiedSpeechAt: TimeInterval
    private var hasActivity = false

    public init(lastSpeechAt: TimeInterval = 0) {
        consumedSpeechAt = lastSpeechAt
        lastNotifiedSpeechAt = lastSpeechAt
    }

    public func hasUnconsumedSpeech(lastSpeechAt: TimeInterval) -> Bool {
        lastSpeechAt > consumedSpeechAt
    }

    /// Call with the current raw meter value, independently of UI meter cadence.
    public mutating func observe(lastSpeechAt: TimeInterval) -> Bool {
        guard lastSpeechAt > lastNotifiedSpeechAt else { return false }
        lastNotifiedSpeechAt = lastSpeechAt
        hasActivity = true
        return true
    }

    public mutating func consume(lastSpeechAt: TimeInterval) {
        consumedSpeechAt = max(consumedSpeechAt, lastSpeechAt)
        lastNotifiedSpeechAt = max(lastNotifiedSpeechAt, lastSpeechAt)
        hasActivity = false
    }

    /// Returns true once per activity burst, only if no words or replay remain.
    public mutating func finishIdle(at time: TimeInterval, lastSpeechAt: TimeInterval,
                                    lastResultAt: TimeInterval, hasUnfinishedText: Bool,
                                    isFinalizing: Bool) -> Bool {
        guard hasActivity, !hasUnfinishedText, !isFinalizing,
              time - max(lastSpeechAt, lastResultAt) >= SpeechAudioHistoryPolicy.endpointSilence else { return false }
        consume(lastSpeechAt: lastSpeechAt)
        return true
    }
}
