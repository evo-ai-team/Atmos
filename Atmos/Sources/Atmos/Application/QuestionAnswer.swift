import Foundation

/// Text replies stay separate from accepted computer tasks and dispatch history.
struct QuestionAnswer: Identifiable {
    let id = UUID()
    let question: String
    let text: String
    let brief: String
    let createdAt = Date()
}
