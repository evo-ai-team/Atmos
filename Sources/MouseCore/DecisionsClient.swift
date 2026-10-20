import Foundation

/// One concrete option supplied by Mouse. Decisions chooses an option; it never invents
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

/// The Decisions endpoint is a classifier, not the Responses tool-generation API.
/// Keep its contract separate: no tools, reasoning controls, service tier, or response
/// history IDs belong here. A new observation produces a new set of closed choices.
public actor DecisionsClient {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    private static let model = "gpt-6-luna"
    private let apiKey: String
    private let transport: Transport

    public init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        self.transport = { request in try await session.data(for: request) }
    }

    // An injected transport makes protocol and cancellation tests entirely offline.
    init(apiKey: String, transport: @escaping Transport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    public func decide(
        instructions: String,
        context: String,
        frame: ScreenshotFrame? = nil,
        questions: [DecisionQuestion]
    ) async throws -> DecisionResult {
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw MouseError.configuration("Add an OpenAI API key in Settings.") }
        try Self.validate(questions)

        // The protocol supports text-only decisions too. Mouse's action selector
        // always attaches its current image; speech extraction uses another client.
        var evidence = [InputPart(text: context)]
        if let frame {
            guard frame.width > 0, frame.height > 0, !frame.data.isEmpty else {
                throw MouseError.configuration("A nonempty screenshot is required.")
            }
            evidence.append(InputPart(imageURL: frame.dataURL))
        }
        let body = RequestBody(
            model: Self.model,
            input: [
                InputMessage(role: "developer", content: [InputPart(text: instructions)]),
                InputMessage(role: "user", content: evidence)
            ],
            questions: questions
        )
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            // A timeout does not tell us whether the server completed. Retrying here
            // could select an action against an observation that is no longer current.
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { throw CancellationError() }
            if error.code == .timedOut {
                throw MouseError.api("OpenAI Decisions did not respond within 30 seconds. The request was not retried.")
            }
            throw MouseError.api("Could not reach OpenAI Decisions. Check your internet connection. The request was not retried.")
        } catch {
            // Never display server bodies or arbitrary transport errors: either may
            // contain request data, transcripts, or credentials.
            throw MouseError.api("The OpenAI Decisions request failed. The request was not retried.")
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MouseError.api("OpenAI Decisions returned an invalid HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else { throw Self.httpError(http.statusCode) }
        return try Self.parseResponse(data, questions: questions)
    }

    private static func validate(_ questions: [DecisionQuestion]) throws {
        guard (1...400).contains(questions.count),
              Set(questions.map(\.name)).count == questions.count else {
            throw MouseError.configuration("Decisions requires 1–400 uniquely named questions.")
        }
        for question in questions {
            guard !question.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !question.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (2...255).contains(question.choices.count),
                  Set(question.choices.map(\.value)).count == question.choices.count,
                  question.choices.allSatisfy({ !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw MouseError.configuration("Each Decisions question needs a name, instructions, and 2–255 distinct choices.")
            }
        }
    }

    /// Validate the complete answer set before returning any selection. Matching the
    /// requested order and names prevents a stale target ID from another question
    /// being accepted simply because it also occurs in the current candidate list.
    static func parseResponse(_ data: Data, questions: [DecisionQuestion]) throws -> DecisionResult {
        let response: ResponseBody
        do { response = try JSONDecoder().decode(ResponseBody.self, from: data) }
        catch { throw invalidResponse() }
        guard response.model == model, response.answers.count == questions.count,
              response.usage.inputTokens >= 0, response.usage.outputTokens >= 0 else {
            throw invalidResponse()
        }

        let answers = try zip(response.answers, questions).map { answer, question in
            guard answer.name == question.name else { throw invalidResponse() }
            if answer.type == "refusal" {
                throw MouseError.api("OpenAI Decisions declined a required decision. No action was selected.")
            }
            guard answer.type == "choice", let choice = answer.choice,
                  let confidence = answer.confidence, validProbability(confidence),
                  let probabilities = answer.probabilities else { throw invalidResponse() }
            let offered = Set(question.choices.map(\.value))
            guard offered.contains(choice), probabilities.count == offered.count,
                  Set(probabilities.map(\.value)) == offered,
                  probabilities.allSatisfy({ validProbability($0.probability) }) else {
                throw invalidResponse()
            }
            return DecisionAnswer(name: question.name, choice: choice, confidence: confidence)
        }
        return DecisionResult(answers: answers, inputTokens: response.usage.inputTokens, outputTokens: response.usage.outputTokens)
    }

    private static func validProbability(_ value: Double) -> Bool {
        value.isFinite && (0...1).contains(value)
    }

    private static func invalidResponse() -> MouseError {
        .api("OpenAI Decisions returned an invalid or mismatched decision. No action was selected.")
    }

    private static func httpError(_ status: Int) -> MouseError {
        switch status {
        case 401: return .api("OpenAI rejected the API key. Update it in Settings.")
        case 403: return .api("This OpenAI project does not have access to Decisions.")
        case 429: return .api("OpenAI rate or usage limit reached. Check your API project limits before trying again.")
        case 400, 404, 422: return .api("OpenAI rejected the Decisions request (HTTP \(status)). Check this project's Decisions access.")
        case 500...599: return .api("OpenAI Decisions is temporarily unavailable (HTTP \(status)). The request was not retried.")
        default: return .api("OpenAI Decisions returned HTTP \(status). The request was not retried.")
        }
    }

    private struct RequestBody: Encodable {
        let model: String
        let input: [InputMessage]
        let questions: [DecisionQuestion]
    }

    private struct InputMessage: Encodable {
        let role: String
        let content: [InputPart]
    }

    private struct InputPart: Encodable {
        let type: String
        let text: String?
        let imageURL: String?
        let detail: String?
        enum CodingKeys: String, CodingKey { case type, text, detail; case imageURL = "image_url" }

        init(text: String) {
            type = "input_text"; self.text = text; imageURL = nil; detail = nil
        }
        init(imageURL: String) {
            type = "input_image"; text = nil; self.imageURL = imageURL; detail = "original"
        }
    }

    private struct ResponseBody: Decodable {
        let model: String
        let answers: [WireAnswer]
        let usage: Usage
    }

    private struct WireAnswer: Decodable {
        let type: String
        let name: String?
        let choice: String?
        let confidence: Double?
        let probabilities: [Probability]?
    }

    private struct Probability: Decodable {
        let value: String
        let probability: Double
    }

    private struct Usage: Decodable {
        let inputTokens: Int
        let outputTokens: Int
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens", outputTokens = "output_tokens"
        }
    }
}
