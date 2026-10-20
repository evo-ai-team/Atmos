import Foundation

/// Keep all detected speech until it is consumed, even if the recognizer has
/// not produced its first words yet. Silence can use a bounded rolling buffer.
public enum SpeechAudioHistoryPolicy {
    public static let endpointSilence: TimeInterval = 0.500
    public static let leadingContext: TimeInterval = 0.6
    public static let idleHistory: TimeInterval = 8

    public static func keepFrom(consumedThrough: TimeInterval, audioEnd: TimeInterval,
                                firstUnconsumedSpeechStart: TimeInterval?, hasUnfinishedText: Bool) -> TimeInterval {
        let consumedFloor = max(0, consumedThrough - leadingContext)
        if hasUnfinishedText { return consumedFloor }
        let idleFloor = max(consumedFloor, audioEnd - idleHistory)
        guard let firstUnconsumedSpeechStart else { return idleFloor }
        return min(idleFloor, max(consumedFloor, firstUnconsumedSpeechStart - leadingContext))
    }

    /// An old coarse result range can mean trimmed leading silence or missing
    /// very quiet words. When timestamps cannot prove coverage, require the
    /// replay to account for the full live text. Reject uncertain corrections
    /// instead of executing a potentially shortened command.
    public static func replayHasCompleteCoverage(firstTextStart: TimeInterval?, retainedAudioStart: TimeInterval,
                                                  provisionalText: String, finalText: String) -> Bool {
        guard let firstTextStart else { return false }
        if firstTextStart + 0.000_001 >= retainedAudioStart { return true }
        func words(_ text: String) -> [String] {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let provisional = words(provisionalText)
        return !provisional.isEmpty && provisional == words(finalText)
    }
}

/// Raw microphone activity must block actions before recognition produces text.
/// A text-free noise burst can release that block after the normal endpoint;
/// a real utterance releases it only once its accurate transcription commits.
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
