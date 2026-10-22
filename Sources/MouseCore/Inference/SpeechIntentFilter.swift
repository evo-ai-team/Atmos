import Foundation

/// A text-only judgment of newly recognized speech. A nil command leaves current work alone.
public struct SpeechIntentResult: Equatable, Sendable {
    public let command: String?
    public let inputTokens: Int
    public let outputTokens: Int

    public init(command: String?, inputTokens: Int, outputTokens: Int) {
        self.command = command
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

/// Extracts task-directed speech independently of the screenshot/action request.
/// This is intent filtering, not speaker identification.
public actor SpeechIntentFilter {
    typealias Transport = APIRequest.Transport

    private let apiKey: String
    private let model: String
    private let serviceTier: String
    private let reasoningEffort: String
    private let transport: APIRequest.MeasuredTransport
    private static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    public init(apiKey: String, model: String = "gpt-6-luna", serviceTier: String = "fast", reasoningEffort: String = "low") {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.transport = APIRequest.ephemeralTransport(label: "Speech screening")
    }

    // Tests inject an offline transport; no saved API key or live model is needed.
    init(apiKey: String, model: String = "gpt-6-luna", serviceTier: String = "fast", reasoningEffort: String = "low",
         transport: @escaping Transport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.transport = APIRequest.measuredTransport(transport)
    }

    public func classify(utterance: String, taskContext: String, timing: PipelineTiming? = nil) async throws -> SpeechIntentResult {
        var stage = timing?.begin("Speech screening request encoding")
        var stageOutcome: PipelineTiming.Outcome = .failed
        defer { timing?.end(stage, outcome: Task.isCancelled ? .cancelled : stageOutcome) }
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw MouseError.configuration("Add an OpenAI API key in Settings.") }
        guard !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MouseError.configuration("A nonempty transcript is required to check speech intent.")
        }
        let body = try SpeechIntentRequest.body(
            utterance: utterance, taskContext: taskContext, model: model,
            serviceTier: serviceTier, reasoningEffort: reasoningEffort
        )
        let request = APIRequest.make(endpoint: Self.endpoint, apiKey: apiKey, body: body)
        timing?.end(stage, outcome: .succeeded)
        stage = timing?.begin("Speech screening HTTP round trip")
        let data: Data
        let response: URLResponse
        do {
            // One judgment only. Failure never authorizes interrupting the active task.
            let measured = try await transport(request, timing)
            measured.diagnostics?.recordClientResume()
            data = measured.data
            response = measured.response
        } catch is CancellationError {
            stageOutcome = .cancelled
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { stageOutcome = .cancelled; throw CancellationError() }
            if error.code == .timedOut { throw MouseError.api("Speech intent checking timed out. Current work was not interrupted.") }
            throw MouseError.api("Could not reach OpenAI to check speech intent. Current work was not interrupted.")
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MouseError.api("Speech intent checking failed. Current work was not interrupted.")
        }
        timing?.end(stage, outcome: (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true ? .succeeded : .failed)
        stage = timing?.begin("Speech screening response parsing")
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw SpeechIntentResponseParser.invalidResponse("Invalid HTTP response.") }
        guard (200...299).contains(http.statusCode) else {
            switch http.statusCode {
            case 401: throw MouseError.api("OpenAI rejected the API key. Update it in Settings.")
            case 403: throw MouseError.api("This OpenAI project cannot use the speech intent model.")
            case 429: throw MouseError.api("OpenAI rate or usage limit reached while checking speech intent.")
            default: throw MouseError.api("Speech intent checking failed (HTTP \(http.statusCode)). Current work was not interrupted.")
            }
        }
        let result = try Self.parseResponse(data)
        stageOutcome = .succeeded
        return result
    }

    static func parseResponse(_ data: Data) throws -> SpeechIntentResult {
        try SpeechIntentResponseParser.parse(data)
    }
}
