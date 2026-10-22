import Foundation

/// Accepts exactly one structured judgment. Failures never become an implicit
/// command or permission to interrupt the task already running.
enum SpeechIntentResponseParser {
    static func parse(_ data: Data) throws -> SpeechIntentResult {
        let response: IntentResponseEnvelope
        do { response = try JSONDecoder().decode(IntentResponseEnvelope.self, from: data) }
        catch { throw invalidResponse("Unreadable response.") }
        guard response.error == nil, response.status == "completed",
              let id = response.id, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let output = response.output else {
            throw invalidResponse("The response did not complete.")
        }
        var resultText: String?
        for item in output {
            guard item.status == nil || item.status == "completed" else {
                throw invalidResponse("An output did not complete.")
            }
            switch item.type {
            case "reasoning":
                break
            case "message":
                guard resultText == nil, item.status == "completed", item.role == "assistant",
                      let content = item.content, content.count == 1,
                      content[0].type == "output_text", let text = content[0].text else {
                    // This also rejects refusals, extra content, or mixed text/tool output.
                    throw invalidResponse("Expected one structured judgment.")
                }
                resultText = text
            default:
                throw invalidResponse("Unexpected output.")
            }
        }
        guard let resultText, let payloadData = resultText.data(using: .utf8),
              let payload = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any],
              Set(payload.keys) == Set(["kind", "command"]),
              let kind = payload["kind"] as? String,
              let rawCommand = payload["command"] as? String else {
            throw invalidResponse("Invalid structured judgment.")
        }
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawCommand.unicodeScalars.allSatisfy({
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t"
        }) else { throw invalidResponse("Invalid command text.") }
        let extracted: String?
        switch kind {
        case "command":
            guard !command.isEmpty else { throw invalidResponse("The command was empty.") }
            extracted = command
        case "ignore":
            guard rawCommand.isEmpty else { throw invalidResponse("Ignore contained command text.") }
            extracted = nil
        default:
            throw invalidResponse("Unknown judgment.")
        }
        let inputTokens = response.usage?.inputTokens ?? 0
        let outputTokens = response.usage?.outputTokens ?? 0
        guard inputTokens >= 0, outputTokens >= 0 else { throw invalidResponse("Invalid usage.") }
        return SpeechIntentResult(command: extracted, inputTokens: inputTokens, outputTokens: outputTokens)
    }

    static func invalidResponse(_ reason: String) -> MouseError {
        .api("Speech intent checking: \(reason) Current work was not interrupted.")
    }
}

private struct IntentResponseEnvelope: Decodable {
    let id: String?
    let status: String?
    let output: [Output]?
    let error: ResponseError?
    let usage: Usage?

    struct ResponseError: Decodable {}
    struct Output: Decodable {
        let type: String
        let status: String?
        let role: String?
        let content: [Content]?
        struct Content: Decodable {
            let type: String
            let text: String?
        }
    }
    struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }
}
