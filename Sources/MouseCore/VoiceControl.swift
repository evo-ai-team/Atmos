import Foundation

/// The initial word "stop" is the only local control. It takes effect on live
/// recognition, before the remaining utterance or accurate replay is available.
public enum VoiceControl: Equatable {
    case sleep

    public static func match(_ text: String) -> VoiceControl? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Quotes and brackets are content. "don't stop" and "type stop" also
        // remain model input, but "stop now" sleeps as soon as "stop" appears.
        guard normalized.hasPrefix("stop") else { return nil }
        let remaining = normalized.dropFirst(4)
        guard remaining.isEmpty || remaining.first.map({ $0.isWhitespace || ",:;.!?".contains($0) }) == true else { return nil }
        return .sleep
    }
}
