import Foundation

/// Treats the entire response as untrusted until its envelope, single operation,
/// task update, and all action arguments have passed validation. No partial batch
/// is returned when any sibling output is invalid.
enum ComputerResponseParser {
    static func parse(_ data: Data) throws -> ModelTurn {
        let response: ResponseEnvelope
        do { response = try JSONDecoder().decode(ResponseEnvelope.self, from: data) }
        catch { throw MouseError.api("OpenAI returned a response that could not be read. No new actions were executed.") }
        guard response.error == nil else { throw MouseError.api("OpenAI could not complete the response. No new actions were executed.") }
        guard response.status == "completed" else {
            if response.incompleteDetails?.reason == "max_output_tokens" {
                throw MouseError.api("The model reached its response limit. No new actions were executed.")
            }
            throw MouseError.api("The model response did not complete. No new actions were executed.")
        }
        guard let id = response.id, !id.isEmpty, let output = response.output else {
            throw MouseError.api("OpenAI returned an incomplete response structure. No new actions were executed.")
        }
        var operation: ModelTurn?
        var messages: [String] = []
        var hasMessageOutput = false
        var hasFinalMessage = false
        for item in output {
            if let status = item.status, status != "completed" {
                throw invalidResponse("A model output did not complete.")
            }
            switch item.type {
            case "function_call":
                guard operation == nil else {
                    throw invalidResponse("The model returned more than one operation.")
                }
                operation = try parseFunction(item, responseID: id)
            case "message":
                hasMessageOutput = true
                for content in item.content ?? [] {
                    if content.type == "refusal" {
                        throw invalidResponse("The model declined this request.")
                    }
                    if content.type == "output_text", let text = content.text, !text.isEmpty {
                        messages.append(text)
                        if item.phase != "commentary" { hasFinalMessage = true }
                    }
                }
            case "reasoning": break
            default:
                throw invalidResponse("The model returned an unsupported output.")
            }
        }
        if var operation {
            // Even an empty message is mixed output. Finish checking every output
            // before returning the operation, so no valid prefix can leak through.
            guard !hasMessageOutput else {
                let reason = operation.ignored
                    ? "The model combined an ignore operation with other output."
                    : "The model combined an operation with a message."
                throw invalidResponse(reason)
            }
            operation.inputTokens = response.usage?.inputTokens ?? 0
            operation.outputTokens = response.usage?.outputTokens ?? 0
            return operation
        }
        guard hasFinalMessage else {
            throw invalidResponse("The model returned no actions or answer.")
        }
        return ModelTurn(
            id: id, calls: [], message: messages.joined(separator: "\n"),
            inputTokens: response.usage?.inputTokens ?? 0,
            outputTokens: response.usage?.outputTokens ?? 0
        )
    }

    private static func parseFunction(_ item: ResponseOutput, responseID: String) throws -> ModelTurn {
        guard let callID = item.callID, !callID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let name = item.name, let arguments = item.arguments,
              arguments.utf8.count <= 200_000,
              let data = arguments.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw invalidResponse("The model returned an invalid function call.")
        }
        switch name {
        case "execute_actions":
            guard Set(payload.keys) == Set(["description", "actions", "task_update"]),
                  let description = payload["description"] as? String,
                  isSingleLine(description, maximum: 64),
                  let rawActions = payload["actions"] as? [[String: Any]],
                  (1...12).contains(rawActions.count) else {
                throw invalidResponse("The action batch is missing a valid short description or actions.")
            }
            let taskUpdate = try parseTaskUpdate(payload["task_update"])
            let actions = try rawActions.map(parseAction)
            let call = ComputerCall(callID: callID, actions: actions, description: description)
            return ModelTurn(id: responseID, calls: [call], taskUpdate: taskUpdate)
        case "pause_for_user":
            guard Set(payload.keys) == Set(["reason", "task_update"]), let reason = payload["reason"] as? String,
                  isSingleLine(reason, maximum: 180) else {
                throw invalidResponse("The model returned an invalid request for user input.")
            }
            let taskUpdate = try parseTaskUpdate(payload["task_update"])
            return ModelTurn(id: responseID, calls: [], pauseReason: reason, taskUpdate: taskUpdate)
        case "ignore_utterance":
            guard payload.isEmpty else {
                throw invalidResponse("The model returned an invalid ignore operation.")
            }
            return ModelTurn(id: responseID, calls: [], ignored: true)
        case "complete_task":
            guard Set(payload.keys) == Set(["message", "task_update"]),
                  let message = payload["message"] as? String,
                  isSingleLine(message, maximum: 180) else {
                throw invalidResponse("The model returned an invalid task completion.")
            }
            let taskUpdate = try parseTaskUpdate(payload["task_update"])
            return ModelTurn(id: responseID, calls: [], message: message, taskUpdate: taskUpdate)
        default:
            throw invalidResponse("The model requested an unsupported function.")
        }
    }

    private static func invalidResponse(_ reason: String) -> MouseError {
        .api(reason + " No new actions were executed.")
    }

    private static func isSingleLine(_ text: String, maximum: Int) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.count <= maximum &&
        text.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
    }

    private static func parseTaskUpdate(_ value: Any?) throws -> TaskUpdate {
        guard let object = value as? [String: Any],
              Set(object.keys) == Set(["kind", "goal"]),
              let rawKind = object["kind"] as? String,
              let kind = TaskUpdate.Kind(rawValue: rawKind),
              let goal = object["goal"] as? String,
              !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              goal.count <= 2_000,
              goal.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t"
              }) else {
            throw invalidResponse("The model returned an invalid task update.")
        }
        return TaskUpdate(kind: kind, goal: goal)
    }

    private static func parseAction(_ object: [String: Any]) throws -> ComputerAction {
        guard let type = object["type"] as? String else { throw invalidResponse("An action has no type.") }
        let fields: [String]
        switch type {
        case "click", "double_click": fields = ["type", "x", "y", "button", "keys"]
        case "move": fields = ["type", "x", "y", "keys"]
        case "scroll": fields = ["type", "x", "y", "scroll_x", "scroll_y", "keys"]
        case "drag": fields = ["type", "path", "keys"]
        case "type": fields = ["type", "text"]
        case "keypress": fields = ["type", "keys"]
        case "wait", "screenshot": fields = ["type"]
        default: throw invalidResponse("The model requested an unsupported action.")
        }
        guard Set(object.keys) == Set(fields),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let action = try? JSONDecoder().decode(ComputerAction.self, from: data) else {
            throw invalidResponse("An action has missing, extra, or incorrectly typed fields.")
        }
        // Decode rejects booleans/strings in numeric fields. NativeComputer additionally
        // checks screenshot bounds, keyboard layout, and permissions before any event.
        for coordinate in [action.x, action.y].compactMap({ $0 }) {
            guard coordinate.isFinite, coordinate >= 0 else { throw invalidResponse("An action has invalid coordinates.") }
        }
        if fields.contains("x"), action.x == nil || action.y == nil {
            throw invalidResponse("An action is missing coordinates.")
        }
        if fields.contains("keys") {
            guard let keys = action.keys, Set(keys).count == keys.count else {
                throw invalidResponse("An action has missing or repeated keys.")
            }
            if type == "keypress" {
                let modifiers = Set(["CMD", "CTRL", "ALT", "SHIFT"])
                guard (1...5).contains(keys.count), keys.allSatisfy({ isSingleLine($0, maximum: 24) }),
                      keys.filter({ !modifiers.contains($0) }).count <= 1 else {
                    throw invalidResponse("A keypress requires one key and up to four modifiers.")
                }
            } else {
                guard keys.count <= 4, keys.allSatisfy({ ["CMD", "CTRL", "ALT", "SHIFT"].contains($0) }) else {
                    throw invalidResponse("A pointer action contains invalid modifier keys.")
                }
            }
        }
        if type == "click" || type == "double_click" {
            guard let button = action.button, ["left", "right", "middle", "back", "forward"].contains(button) else {
                throw invalidResponse("An action has an unsupported mouse button.")
            }
        }
        if type == "scroll" {
            guard let x = action.scrollX, let y = action.scrollY, x.isFinite, y.isFinite,
                  abs(x) <= 100_000, abs(y) <= 100_000 else { throw invalidResponse("An action has invalid scroll distances.") }
        }
        if type == "drag" {
            guard let path = action.path, (2...100).contains(path.count),
                  let rawPath = object["path"] as? [[String: Any]],
                  rawPath.allSatisfy({ Set($0.keys) == Set(["x", "y"]) }),
                  path.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 }) else {
                throw invalidResponse("An action has an invalid drag path.")
            }
        }
        if type == "type" {
            guard let text = action.text, !text.isEmpty, text.count <= 10_000,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t" }) else {
                throw invalidResponse("An action has invalid typed text.")
            }
        }
        return action
    }

}

private struct ResponseEnvelope: Decodable {
    var id: String?
    var status: String?
    var output: [ResponseOutput]?
    var error: ResponseError?
    var incompleteDetails: IncompleteDetails?
    var usage: Usage?
    enum CodingKeys: String, CodingKey { case id, status, output, error, usage; case incompleteDetails = "incomplete_details" }
    struct ResponseError: Decodable {}
    struct IncompleteDetails: Decodable { var reason: String? }
    struct Usage: Decodable {
        var inputTokens: Int?
        var outputTokens: Int?
        enum CodingKeys: String, CodingKey { case inputTokens = "input_tokens", outputTokens = "output_tokens" }
    }
}

private struct ResponseOutput: Decodable {
    var type: String
    var status: String?
    var phase: String?
    var callID: String?
    var name: String?
    var arguments: String?
    var content: [Content]?
    enum CodingKeys: String, CodingKey {
        case type, status, phase, name, arguments, content
        case callID = "call_id"
    }
    struct Content: Decodable { var type: String; var text: String? }
}
