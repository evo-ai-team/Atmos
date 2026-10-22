import Foundation

/// A compact presentation label. Full model/native descriptions remain in the
/// action history; this formatting never changes a target or dispatched action.
public enum ActionLabel {
    public static func compact(_ description: String) -> String {
        let clean = description.replacingOccurrences(of: #"\.{3,}|…"#, with: " ", options: .regularExpression)
        let words = clean.components(separatedBy: .whitespacesAndNewlines.union(.controlCharacters))
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard let action = words.first, action.count <= 24 else { return "Working" }

        // Older/native labels can say "Click the Home button". Keep a useful
        // target word instead of spending the second word on its article.
        let target = words.dropFirst().drop { ["a", "an", "the"].contains($0.lowercased()) }.first
        guard let target, target.count <= 24 else { return action }
        return "\(action) \(target)"
    }
}
