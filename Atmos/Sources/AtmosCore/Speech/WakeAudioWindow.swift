import Foundation

/// Apple's first word can carry a range beginning in long-discarded standby
/// silence. Bound the audio sent to the service and recheck the wake whenever
/// its precise position cannot be established.
public struct WakeAudioWindow {
    public struct Selection: Equatable {
        public let start: TimeInterval
        public let verifyWake: Bool
    }

    private var firstPrefixAt: TimeInterval?
    public init() {}

    public static func containsWake(_ text: String) -> Bool {
        var probe = WakeSession()
        return probe.receive(text, at: 0).contains(.activated)
    }

    /// Put an unconfirmed empty stream back to sleep. A long turn with live
    /// words may still correct the wake name when the accurate replay returns.
    public static func emptyConfirmationExpired(audioDuration: TimeInterval, hasWords: Bool,
                                                heardWake: Bool, silence: TimeInterval) -> Bool {
        !heardWake && !hasWords && audioDuration > 6 && silence >= SpeechAudioHistoryPolicy.endpointSilence
    }

    public mutating func observe(_ text: String, at captureTime: TimeInterval) {
        if Self.containsWake(text) || WakeSession.isPossibleWakePrefix(text) {
            if firstPrefixAt == nil { firstPrefixAt = captureTime }
        } else { firstPrefixAt = nil }
    }

    public func select(attributedStart: TimeInterval?, earliest: TimeInterval,
                       latest: TimeInterval, recentOnset: TimeInterval?) -> Selection? {
        let evidence = firstPrefixAt ?? latest
        let floor = max(earliest, evidence - 2)
        guard latest >= floor, evidence >= earliest, latest - evidence < 6 else { return nil }
        if let attributedStart, attributedStart >= floor, attributedStart <= latest {
            return Selection(start: attributedStart, verifyWake: false)
        }
        // Lead the detected onset to retain soft consonants. If the gate missed
        // the voice entirely, include the full two seconds before first evidence.
        let start = recentOnset.map { max(floor, min(evidence - 0.6, $0 - 0.6)) } ?? floor
        return Selection(start: start, verifyWake: true)
    }

    public var prefixTime: TimeInterval? { firstPrefixAt }
}
