import Foundation

/// One concrete option supplied by Atmos. Decisions chooses an option; it never invents
/// an action, a coordinate, or text to type. The caller retains the executable payload.
public struct DecisionChoice: Equatable, Sendable, Encodable {
    public let value: String
    public let description: String

    public init(value: String, description: String) {
        self.value = value
        self.description = description
    }
}

public struct DecisionQuestion: Equatable, Sendable, Encodable {
    public let name: String
    public let instructions: String
    public let choices: [DecisionChoice]
    private let type = "choice"

    public init(name: String, instructions: String, choices: [DecisionChoice]) {
        self.name = name
        self.instructions = instructions
        self.choices = choices
    }
}

public struct DecisionAnswer: Equatable, Sendable {
    public let name: String
    public let choice: String
    public let confidence: Double

    public init(name: String, choice: String, confidence: Double) {
        self.name = name
        self.choice = choice
        self.confidence = confidence
    }
}

public struct DecisionResult: Equatable, Sendable {
    public let answers: [DecisionAnswer]
    public let inputTokens: Int
    public let outputTokens: Int

    public init(answers: [DecisionAnswer], inputTokens: Int, outputTokens: Int) {
        self.answers = answers
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public func answer(named name: String) -> DecisionAnswer? {
        answers.first { $0.name == name }
    }
}

