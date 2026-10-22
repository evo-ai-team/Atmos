import Foundation

/// The Decisions endpoint is a classifier, not the Responses tool-generation API.
/// Keep its contract separate: no tools, reasoning controls, service tier, or response
/// history IDs belong here. Text-only is the default; only the explicitly selected
/// image mode supplies a frame. A new observation produces new closed choices.
public actor DecisionsClient {
    typealias Transport = APIRequest.Transport

    private static let endpoint = URL(string: "https://api.openai.com/v1/decisions")!
    private static let model = "gpt-6-luna"
    private let apiKey: String
    private let transport: APIRequest.MeasuredTransport

    public init(apiKey: String) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = APIRequest.ephemeralTransport(label: "Decisions")
    }

    // An injected transport makes protocol and cancellation tests entirely offline.
    init(apiKey: String, transport: @escaping Transport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = APIRequest.measuredTransport(transport)
    }

    public func decide(
        instructions: String,
        context: String,
        questions: [DecisionQuestion],
        frame: ScreenshotFrame? = nil,
        timing: PipelineTiming? = nil
    ) async throws -> DecisionResult {
        var stage = timing?.begin("Decisions request encoding")
        var stageOutcome: PipelineTiming.Outcome = .failed
        defer { timing?.end(stage, outcome: Task.isCancelled ? .cancelled : stageOutcome) }
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw MouseError.configuration("Add an OpenAI API key in Settings.") }
        try Self.validate(questions)
        if let frame, frame.width <= 0 || frame.height <= 0 || frame.data.isEmpty {
            throw MouseError.configuration("A nonempty screenshot is required for image Decisions.")
        }
        var content = [InputPart(text: context)]
        if let frame { content.append(InputPart(frame: frame)) }

        let body = RequestBody(
            model: Self.model,
            input: [
                InputMessage(role: "developer", content: [InputPart(text: instructions)]),
                InputMessage(role: "user", content: content)
            ],
            questions: questions
        )
        let imageSummary = frame.map { "image; screenshot \($0.width)×\($0.height)" } ?? "text-only; screenshot none"
        timing?.annotate("Decisions request shape: \(imageSummary); context UTF-8 \(context.utf8.count) bytes; \(questions.count) question(s), \(questions.reduce(0) { $0 + $1.choices.count }) total choices")
        let request = APIRequest.make(
            endpoint: Self.endpoint, apiKey: apiKey, body: try JSONEncoder().encode(body)
        )

        timing?.end(stage, outcome: .succeeded)
        stage = timing?.begin("Decisions HTTP round trip")
        let data: Data
        let response: URLResponse
        let diagnostics: HTTPRequestTiming?
        do {
            // A timeout does not tell us whether the server completed. Retrying here
            // could select an action against an observation that is no longer current.
            let measured = try await transport(request, timing)
            measured.diagnostics?.recordClientResume()
            data = measured.data
            response = measured.response
            diagnostics = measured.diagnostics
        } catch is CancellationError {
            stageOutcome = .cancelled
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { stageOutcome = .cancelled; throw CancellationError() }
            if error.code == .timedOut {
                throw MouseError.api("OpenAI Decisions did not respond within 30 seconds. The request was not retried.")
            }
            throw MouseError.api("Could not reach OpenAI Decisions. Check your internet connection. The request was not retried.")
        } catch {
            // Never display server bodies or arbitrary transport errors: either may
            // contain request data, transcripts, or credentials.
            throw MouseError.api("The OpenAI Decisions request failed. The request was not retried.")
        }
        // This measures the transport await, including network and server time;
        // it is not a claim about model inference time alone.
        timing?.end(stage, outcome: (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true ? .succeeded : .failed)
        stage = timing?.begin("Decisions response parsing")
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw MouseError.api("OpenAI Decisions returned an invalid HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else { throw Self.httpError(http.statusCode) }
        let result = try Self.parseResponse(data, questions: questions)
        let tokenSummary = "response usage: \(result.inputTokens) input tokens, \(result.outputTokens) output tokens"
        if let diagnostics { diagnostics.annotate(tokenSummary) }
        else { timing?.annotate("Decisions \(tokenSummary)") }
        stageOutcome = .succeeded
        return result
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

        init(frame: ScreenshotFrame) {
            type = "input_image"; text = nil; imageURL = frame.dataURL; detail = "original"
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
