import Foundation

/// Generates UI actions when the Decisions selector cannot use an observed
/// candidate. The caller owns execution; this client never operates the Mac.
public actor OpenAIComputerClient {
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
        self.transport = APIRequest.ephemeralTransport(label: "Responses")
    }

    // Internal transport injection keeps tests offline without exposing credentials to fixtures.
    init(apiKey: String, model: String = "gpt-6-luna", serviceTier: String = "fast", reasoningEffort: String = "low", transport: @escaping Transport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model
        self.serviceTier = serviceTier
        self.reasoningEffort = reasoningEffort
        self.transport = APIRequest.measuredTransport(transport)
    }

    /// Each fallback request starts from fresh observations instead of a hidden
    /// response chain. Decisions owns the interstep loop and may have acted since
    /// the last generative call, so only the caller's dispatched history is current.
    public func begin(command: String, frame: ScreenshotFrame, context: String, activeTask: String = "",
                      pendingClarification: String? = nil,
                      accessibility: AccessibilitySnapshot? = nil, continuingTask: Bool = false,
                      reviewRequired: Bool = false, timing: PipelineTiming? = nil) async throws -> ModelTurn {
        var preparation = timing?.begin("Responses input preparation")
        var preparationOutcome: PipelineTiming.Outcome = .failed
        defer { timing?.end(preparation, outcome: Task.isCancelled ? .cancelled : preparationOutcome) }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MouseError.configuration("Enter a command before starting.")
        }
        guard !continuingTask || !activeTask.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MouseError.configuration("An accepted active task is required to continue.")
        }
        try validate(frame)
        let input = ComputerRequest.initialInput(
            command: command, frame: frame, context: context, activeTask: activeTask,
            pendingClarification: pendingClarification, accessibility: accessibility?.contextText ?? "",
            continuingTask: continuingTask
        )
        let policy = ComputerRequestPolicy(
            reviewRequired: reviewRequired, allowIgnore: !continuingTask, allowAnswer: !continuingTask,
            accessibility: accessibility
        )
        preparationOutcome = .succeeded
        timing?.end(preparation, outcome: preparationOutcome)
        preparation = nil
        return try await send(input: input, previousResponseID: nil, policy: policy, timing: timing)
    }

    public func continueTurn(responseID: String, outputs: [(callID: String, frame: ScreenshotFrame)], timing: PipelineTiming? = nil) async throws -> ModelTurn {
        var preparation = timing?.begin("Responses input preparation")
        var preparationOutcome: PipelineTiming.Outcome = .failed
        defer { timing?.end(preparation, outcome: Task.isCancelled ? .cancelled : preparationOutcome) }
        guard !responseID.isEmpty, !outputs.isEmpty,
              outputs.allSatisfy({ !$0.callID.isEmpty }),
              Set(outputs.map(\.callID)).count == outputs.count else {
            throw MouseError.configuration("A response and distinct computer call outputs are required to continue.")
        }
        let input: [[String: Any]] = try outputs.map { output in
            try validate(output.frame)
            return [
                "type": "function_call_output",
                "call_id": output.callID,
                "output": [
                    ["type": "input_text", "text": "Continuing accepted task; no new user utterance. The action batch was dispatched; that alone does not prove success. Inspect this fresh screenshot against the entire goal and dispatched history. Call complete_task immediately if the goal is satisfied; otherwise choose the next necessary operation or pause. Screenshot size: \(output.frame.width) × \(output.frame.height) pixels."],
                    ["type": "input_image", "image_url": output.frame.dataURL, "detail": "original"]
                ]
            ]
        }
        preparationOutcome = .succeeded
        timing?.end(preparation, outcome: preparationOutcome)
        preparation = nil
        return try await send(input: input, previousResponseID: responseID,
                              policy: ComputerRequestPolicy(allowIgnore: false, allowAnswer: false), timing: timing)
    }

    private func validate(_ frame: ScreenshotFrame) throws {
        guard frame.width > 0, frame.height > 0, !frame.data.isEmpty else {
            throw MouseError.configuration("A nonempty screenshot is required.")
        }
    }

    private func send(input: [[String: Any]], previousResponseID: String?,
                      policy: ComputerRequestPolicy = ComputerRequestPolicy(), timing: PipelineTiming? = nil) async throws -> ModelTurn {
        var stage = timing?.begin("Responses request encoding")
        var stageOutcome: PipelineTiming.Outcome = .failed
        defer { timing?.end(stage, outcome: Task.isCancelled ? .cancelled : stageOutcome) }
        try Task.checkCancellation()
        guard !apiKey.isEmpty else { throw MouseError.configuration("Add an OpenAI API key in Settings.") }
        let body = try ComputerRequest.body(
            input: input, previousResponseID: previousResponseID, model: model,
            serviceTier: serviceTier, reasoningEffort: reasoningEffort, policy: policy
        )
        let request = APIRequest.make(endpoint: Self.endpoint, apiKey: apiKey, body: body)
        timing?.end(stage, outcome: .succeeded)
        stage = timing?.begin("Responses HTTP round trip")
        let data: Data
        let response: URLResponse
        do {
            // Deliberately no retries: replaying a response could duplicate a UI action.
            let measured = try await transport(request, timing)
            measured.diagnostics?.recordClientResume()
            data = measured.data
            response = measured.response
        } catch is CancellationError {
            stageOutcome = .cancelled
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled { stageOutcome = .cancelled; throw CancellationError() }
            if error.code == .timedOut { throw MouseError.api("OpenAI did not respond within 30 seconds. The request was not retried.") }
            throw MouseError.api("Could not reach OpenAI. Check your internet connection. The request was not retried.")
        } catch {
            throw MouseError.api("The OpenAI request failed. The request was not retried.")
        }
        timing?.end(stage, outcome: (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true ? .succeeded : .failed)
        stage = timing?.begin("Responses response parsing")
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw MouseError.api("OpenAI returned an invalid HTTP response.") }
        guard (200...299).contains(http.statusCode) else { throw Self.httpError(http.statusCode) }
        let turn = try Self.parseResponse(data)
        try policy.validate(turn)
        stageOutcome = .succeeded
        return turn
    }

    private static func httpError(_ status: Int) -> MouseError {
        switch status {
        case 401: return .api("OpenAI rejected the API key. Update it in Settings.")
        case 403: return .api("This OpenAI project does not have permission for the requested model or tool.")
        case 429: return .api("OpenAI rate or usage limit reached. Check your API project limits before trying again.")
        case 400, 404, 422: return .api("OpenAI rejected the request (HTTP \(status)). Check the model and service tier in Settings.")
        case 500...599: return .api("OpenAI is temporarily unavailable (HTTP \(status)). The request was not retried.")
        default: return .api("OpenAI returned HTTP \(status). The request was not retried.")
        }
    }

    static func parseResponse(_ data: Data) throws -> ModelTurn {
        try ComputerResponseParser.parse(data)
    }
}
