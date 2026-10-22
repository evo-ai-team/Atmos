import Foundation

/// Text replies stay separate from accepted computer tasks and dispatch history.
struct QuestionAnswer: Identifiable {
    let id = UUID()
    let question: String
    let text: String
    let createdAt = Date()

    /// Keep the notch readable; the Answers tab always retains the complete text.
    var preview: String {
        guard text.count > 280 else { return text }
        return String(text.prefix(240)) + "…\nFull answer in Answers."
    }
}
