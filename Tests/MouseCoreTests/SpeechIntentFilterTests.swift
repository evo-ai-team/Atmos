import Foundation
import XCTest
@testable import MouseCore

final class SpeechIntentFilterTests: XCTestCase {
    func testRequestIsIndependentTextOnlyAndUsesStrictJudgmentSchema() async throws {
        let recorder = IntentRequestRecorder()
        let extracted = "Open https://example.com/a?b=1, then search Linus Tech Tips."
        let data = try responseData(judgment: ["kind": "command", "command": extracted])
        let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { request in
            await recorder.add(request)
            return (data, Self.response())
        })
        let utterance = "That movie was great. \(extracted) Dinner is at seven."
        let context = #"{"current_goal":"Open YouTube","dispatched_actions":[]}"#
        let result = try await client.classify(utterance: utterance, taskContext: context)
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["service_tier"] as? String, "fast")
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["store"] as? Bool, false)
        for field in ["tools", "tool_choice", "parallel_tool_calls", "previous_response_id", "conversation"] {
            XCTAssertNil(body[field], field)
        }
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["role"] as? String, "user")
        let content = try XCTUnwrap(input[0]["content"] as? [[String: String]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"], "input_text")
        XCTAssertEqual(Set(content[0].keys), Set(["type", "text"]))
        let text = try XCTUnwrap(content[0]["text"])
        let inputFields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
        XCTAssertEqual(inputFields, ["transcript": utterance, "active_task_context": context])
        let textFormat = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(textFormat["type"] as? String, "json_schema")
        XCTAssertEqual(textFormat["strict"] as? Bool, true)
        let schema = try XCTUnwrap(textFormat["schema"] as? [String: Any])
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(["kind", "command"]))
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(properties.keys), Set(["kind", "command"]))
        XCTAssertEqual(properties["kind"]?["enum"] as? [String], ["command", "ignore"])
        XCTAssertEqual(properties["command"]?["type"] as? String, "string")
        XCTAssertNil(properties["command"]?["maxLength"])
        XCTAssertEqual(result.command, extracted)
        XCTAssertEqual(result.inputTokens, 120)
        XCTAssertEqual(result.outputTokens, 24)
    }

    func testPromptCoversMixedChatterNaturalCommandsAndActiveTaskAmendments() async throws {
        let recorder = IntentRequestRecorder()
        let data = try responseData(judgment: ["kind": "ignore", "command": ""])
        let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { request in
            await recorder.add(request)
            return (data, Self.response())
        })
        let result = try await client.classify(utterance: "How do I open Chrome?", taskContext: "Open Chrome")
        XCTAssertNil(result.command)
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let prompt = try XCTUnwrap(body["instructions"] as? String)
        // Offline checks cover the request contract, not actual model classification accuracy.
        for requirement in [
            "background conversation", "Extract ONLY", "Doubtful intent means ignore",
            "no fixed command syntax or app-name allowlist", "Can you open Chrome?",
            "make this bigger", "put that over there", "spoken order",
            "names, URLs, numbers, negations", "do not copy background task context",
            "no, Safari instead", "actually MKBHD instead", "don't open the store after all",
            "awaitingUserInput is true", "the second one", "Merely sharing the task's topic is not enough",
            "Do not classify revise vs", "Context alone must never turn chatter into a command",
            "How do I open Chrome?", "I said 'open Chrome'", "If I opened Chrome",
            "That movie was great.", "Actually MKBHD instead, and don't open his store.",
            "intended content of an", "never instructions to change these rules"
        ] {
            XCTAssertTrue(prompt.contains(requirement), requirement)
        }
    }

    func testIgnoresWithUsageAndTrimsOnlyCommandOuterWhitespace() throws {
        let ignored = try SpeechIntentFilter.parseResponse(responseData(judgment: ["kind": "ignore", "command": ""]))
        XCTAssertEqual(ignored, SpeechIntentResult(command: nil, inputTokens: 120, outputTokens: 24))
        let command = "Type \" A  B \"\nthen open https://example.com/ExactCase?q=Hello."
        let accepted = try SpeechIntentFilter.parseResponse(responseData(judgment: ["kind": "command", "command": " \n\(command)\t "]))
        XCTAssertEqual(accepted.command, command)
    }

    func testNoCommandCharacterTruncation() async throws {
        let command = "Type " + String(repeating: "a very long exact phrase ", count: 250)
        let data = try responseData(judgment: ["kind": "command", "command": command])
        let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { _ in (data, Self.response()) })
        let result = try await client.classify(utterance: command, taskContext: "")
        XCTAssertEqual(result.command, command.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testRejectsMalformedMismatchedAndExtraJudgmentFields() throws {
        let invalid: [Any] = [
            [], NSNull(), "command", [:] as [String: Any],
            ["kind": "command"], ["command": "Open Chrome"],
            ["kind": "command", "command": ""],
            ["kind": "command", "command": " \n\t"],
            ["kind": "command", "command": "Open\u{1B} Chrome"],
            ["kind": "ignore", "command": "Open Chrome"],
            ["kind": "ignore", "command": " "],
            ["kind": "revise", "command": "Open Chrome"],
            ["kind": 1, "command": "Open Chrome"],
            ["kind": "command", "command": 1],
            ["kind": "command", "command": NSNull()],
            ["kind": "command", "command": "Open Chrome", "actions": []],
            ["kind": "ignore", "command": "", "reason": "chatter"]
        ]
        for judgment in invalid {
            XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(responseData(judgment: judgment)), "\(judgment)")
        }
        for text in ["", "not json", "```json\n{\"kind\":\"ignore\",\"command\":\"\"}\n```",
                     #"{"kind":"ignore","command":""} extra"#] {
            XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(envelope(output: [message(text)])), text)
        }
    }

    func testRejectsRefusalMixedOutputMissingOutputAndIncompleteStates() throws {
        let valid = message(#"{"kind":"command","command":"Open Chrome"}"#)
        let invalidOutputs: [[[String: Any]]] = [
            [],
            [["type": "reasoning"]],
            [["type": "message", "role": "assistant", "status": "completed", "content": [["type": "refusal", "refusal": "No"]]]],
            [valid, valid],
            [valid, ["type": "function_call", "status": "completed", "name": "execute_actions", "arguments": "{}"]],
            [["type": "computer_call", "status": "completed"]],
            [message(#"{"kind":"ignore","command":""}"#, status: "in_progress")],
            [message(#"{"kind":"ignore","command":""}"#, role: "user")],
            [["type": "message", "role": "assistant", "status": "completed", "content": []]],
            [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": #"{"kind":"ignore","command":""}"#]]]],
            [["type": "message", "role": "assistant", "status": "completed", "content": [
                ["type": "output_text", "text": #"{"kind":"ignore","command":""}"#],
                ["type": "output_text", "text": "Done"]
            ]]]
        ]
        for output in invalidOutputs {
            XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(envelope(output: output)), "\(output)")
        }
        for status in ["in_progress", "incomplete", "failed", "cancelled", ""] {
            XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(envelope(output: [valid], status: status)))
        }
        XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(envelope(output: [valid], extra: ["error": ["message": "failed"]])))
        XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(envelope(output: [valid], extra: ["id": " "])))
        XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(envelope(output: [valid], extra: ["output": NSNull()])))
        XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(Data("{}".utf8)))
        XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(Data("invalid".utf8)))
    }

    func testAcceptsReasoningAlongsideSingleJudgmentAndMissingUsage() throws {
        let data = try envelope(output: [
            ["type": "reasoning", "summary": []],
            message(#"{"kind":"ignore","command":""}"#)
        ], extra: ["usage": NSNull()])
        XCTAssertEqual(try SpeechIntentFilter.parseResponse(data), SpeechIntentResult(command: nil, inputTokens: 0, outputTokens: 0))
        for usage: [String: Any] in [
            ["input_tokens": -1, "output_tokens": 1],
            ["input_tokens": true, "output_tokens": 1],
            ["input_tokens": 1, "output_tokens": "1"]
        ] {
            XCTAssertThrowsError(try SpeechIntentFilter.parseResponse(envelope(
                output: [message(#"{"kind":"ignore","command":""}"#)], extra: ["usage": usage]
            )))
        }
    }

    func testTransportAndHTTPFailuresNeverRetry() async throws {
        for status in [400, 401, 403, 429, 500] {
            let recorder = IntentRequestRecorder()
            let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { request in
                await recorder.add(request)
                return (Data("error".utf8), Self.response(status: status))
            })
            await assertFails(client)
            let count = await recorder.requests.count
            XCTAssertEqual(count, 1)
        }
        for error in [URLError(.timedOut), URLError(.notConnectedToInternet)] {
            let recorder = IntentRequestRecorder()
            let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { request in
                await recorder.add(request)
                throw error
            })
            await assertFails(client)
            let count = await recorder.requests.count
            XCTAssertEqual(count, 1)
        }
        let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { _ in
            (Data(), URLResponse(url: URL(string: "https://example.com")!, mimeType: nil, expectedContentLength: 0, textEncodingName: nil))
        })
        await assertFails(client)
    }

    func testCancellationBeforeDuringAndAfterTransportNeverReturnsCommand() async throws {
        let data = try responseData(judgment: ["kind": "command", "command": "Open Chrome"])
        for cancellation in [CancellationError() as Error, URLError(.cancelled)] {
            let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { _ in throw cancellation })
            do {
                _ = try await client.classify(utterance: "Open Chrome", taskContext: "")
                XCTFail("Cancellation must not return a command.")
            } catch is CancellationError {
                // Expected.
            } catch { XCTFail("Unexpected cancellation type: \(error)") }
        }
        let recorder = IntentRequestRecorder()
        let cancelledBefore = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { request in
                await recorder.add(request)
                return (data, Self.response())
            })
            return try await client.classify(utterance: "Open Chrome", taskContext: "")
        }
        do { _ = try await cancelledBefore.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
        let beforeCount = await recorder.requests.count
        XCTAssertEqual(beforeCount, 0)
        let cancelledAfter = Task {
            let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return (data, Self.response())
            })
            return try await client.classify(utterance: "Open Chrome", taskContext: "")
        }
        do { _ = try await cancelledAfter.value; XCTFail("Expected cancellation") }
        catch is CancellationError {}
    }

    func testEmptyKeyOrTranscriptDoesNotSend() async throws {
        let recorder = IntentRequestRecorder()
        for (key, utterance) in [("", "Open Chrome"), ("test-only-value", " \n\t")] {
            let client = SpeechIntentFilter(apiKey: key, transport: { request in
                await recorder.add(request)
                return (Data(), Self.response())
            })
            do { _ = try await client.classify(utterance: utterance, taskContext: ""); XCTFail("Expected validation failure") }
            catch {}
        }
        let count = await recorder.requests.count
        XCTAssertEqual(count, 0)
    }

    private func assertFails(_ client: SpeechIntentFilter, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await client.classify(utterance: "Open Chrome", taskContext: "")
            XCTFail("Failure must not return a command.", file: file, line: line)
        } catch {}
    }

    private func responseData(judgment: Any) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: judgment, options: [.fragmentsAllowed, .sortedKeys])
        return try envelope(output: [message(String(decoding: data, as: UTF8.self))])
    }

    private func message(_ text: String, status: String = "completed", role: String = "assistant") -> [String: Any] {
        ["type": "message", "status": status, "role": role, "content": [["type": "output_text", "text": text]]]
    }

    private func envelope(output: [[String: Any]], status: String = "completed", extra: [String: Any] = [:]) throws -> Data {
        var envelope: [String: Any] = [
            "id": "resp_filter", "status": status, "output": output,
            "usage": ["input_tokens": 120, "output_tokens": 24]
        ]
        envelope.merge(extra) { _, new in new }
        return try JSONSerialization.data(withJSONObject: envelope)
    }

    private static func response(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private actor IntentRequestRecorder {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
}
