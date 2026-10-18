import Foundation

/// Bare "stop" is the only local control. Every other completed active, idle
/// utterance goes to the model for a semantic act-or-ignore decision.
public enum VoiceControl: Equatable {
    case sleep

    public static func match(_ text: String) -> VoiceControl? {
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Sentence punctuation is incidental; quotes and brackets are content
        // and must reach the model rather than becoming a local stop.
        while let last = normalized.last, ".!?".contains(last) { normalized.removeLast() }
        return normalized.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "stop" ? .sleep : nil
    }
}
