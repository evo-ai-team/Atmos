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

    // These mocks verify context transport and output preservation. They do not
    // establish the model's semantic accuracy on chatter or elliptical requests.
    func testContextualFollowUpWireContractPreservesOriginalFragments() async throws {
        let cases: [(fragment: String, command: String, goal: String, action: String, clarification: String?)] = [
            ("can you open that?", "Find the product", "Show the product page", "Opened product results", nil),
            ("and their store", "Open the creator's channel", "Show the creator's channel", "Opened the channel page", nil),
            ("what about the blue one?", "Select the ivory color", "Show this product in ivory", "Clicked the Ivory color option", nil),
            ("the second one", "Open the product", "Show the requested product", "Opened matching products", "Which of these two products?")
        ]
        for item in cases {
            let historyData = try JSONSerialization.data(withJSONObject: [[
                "command": item.command,
                "status": item.clarification == nil ? "completed" : "paused",
                "outcome": item.clarification ?? "Done",
                "resolvedGoal": item.goal,
                "lastDispatchedActionDescription": item.action
            ]], options: [.sortedKeys])
            let history = String(decoding: historyData, as: UTF8.self)
            let contextData = try JSONSerialization.data(withJSONObject: [
                "currentGoal": item.clarification == nil ? NSNull() : item.goal as Any,
                "acceptedPendingCommands": [] as [String],
                "awaitingUserInput": item.clarification != nil,
                "clarification": item.clarification as Any? ?? NSNull(),
                "lastAcceptedCommand": item.command,
                "lastAcceptedGoal": item.goal,
                "recentAcceptedCommands": history
            ], options: [.sortedKeys])
            let context = String(decoding: contextData, as: UTF8.self)
            let recorder = IntentRequestRecorder()
            let data = try responseData(judgment: ["kind": "command", "command": item.fragment])
            let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { request in
                await recorder.add(request)
                return (data, Self.response())
            })

            let result = try await client.classify(utterance: item.fragment, taskContext: context)
            XCTAssertEqual(result.command, item.fragment)
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
            let fields = try inputFields(XCTUnwrap(requests.first))
            XCTAssertEqual(fields, ["transcript": item.fragment, "active_task_context": context])
            let transportedContext = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(XCTUnwrap(fields["active_task_context"]).utf8)) as? [String: Any])
            XCTAssertEqual(transportedContext["recentAcceptedCommands"] as? String, history)
            XCTAssertEqual(transportedContext["clarification"] as? String, item.clarification)
        }
    }

    func testCompleteAcceptedContextIsEncodedAsDataWithoutTruncation() async throws {
        let acceptedCommand = "Type \"A  B\"\n" + String(repeating: "Keep the full accepted request, café, and https://example.com/ExactCase?q=Blue. ", count: 150)
        let historyData = try JSONSerialization.data(withJSONObject: [[
            "command": acceptedCommand,
            "status": "completed",
            "outcome": "The previous task finished.",
            "resolvedGoal": "Inspect the selected product’s color options",
            "lastDispatchedActionDescription": "Clicked \"Ivory\"\nNative accessibility"
        ]], options: [.sortedKeys])
        let history = String(decoding: historyData, as: UTF8.self)
        let contextData = try JSONSerialization.data(withJSONObject: [
            "currentGoal": "Compare product colors",
            "acceptedPendingCommands": ["and their store", "actually the blue one"],
            "awaitingUserInput": true,
            "clarification": "The light blue or dark blue option?",
            "lastAcceptedCommand": acceptedCommand,
            "lastAcceptedGoal": "Inspect the selected product’s color options",
            "recentAcceptedCommands": history
        ], options: [.sortedKeys])
        let context = String(decoding: contextData, as: UTF8.self)
        let recorder = IntentRequestRecorder()
        let data = try responseData(judgment: ["kind": "command", "command": "the dark blue one"])
        let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { request in
            await recorder.add(request)
            return (data, Self.response())
        })

        let result = try await client.classify(utterance: "the dark blue one", taskContext: context)
        XCTAssertEqual(result.command, "the dark blue one")
        let requests = await recorder.requests
        let fields = try inputFields(XCTUnwrap(requests.first))
        XCTAssertEqual(fields, ["transcript": "the dark blue one", "active_task_context": context])
    }

    func testIgnoreWireResultDoesNotFallbackToAcceptedContext() async throws {
        let context = #"{"currentGoal":null,"recentAcceptedCommands":[{"command":"Open their store","status":"completed","resolvedGoal":"Open the creator's store"}]}"#
        let data = try responseData(judgment: ["kind": "ignore", "command": ""])
        let client = SpeechIntentFilter(apiKey: "test-only-value", transport: { _ in (data, Self.response()) })
        let result = try await client.classify(utterance: "Their store is expensive. Why is blue light scattered?", taskContext: context)
        XCTAssertNil(result.command)
        XCTAssertEqual(result.inputTokens, 120)
        XCTAssertEqual(result.outputTokens, 24)
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

    func testSpeechTimingClosesEachStageWithoutRecordingTranscript() async throws {
        let timing = PipelineTiming(origin: .speech)
        let data = try responseData(judgment: ["kind": "command", "command": "Open Search"])
        let client = SpeechIntentFilter(apiKey: "private-key", transport: { _ in
            XCTAssertTrue(timing.report.contains("running · Speech screening HTTP round trip"))
            return (data, Self.response())
        })
        let result = try await client.classify(utterance: "private-utterance", taskContext: "private-context", timing: timing)
        XCTAssertEqual(result.command, "Open Search")
        for stage in ["request encoding", "HTTP round trip", "response parsing"] {
            XCTAssertTrue(timing.report.contains("succeeded · Speech screening \(stage)"))
            XCTAssertFalse(timing.report.contains("running · Speech screening \(stage)"))
        }
        XCTAssertFalse(timing.report.contains("private-"))
        XCTAssertTrue(timing.report.contains("First input attempt: none"))
    }

    func testCancelledSpeechTransportClosesItsTiming() async {
        let timing = PipelineTiming(origin: .speech)
        let client = SpeechIntentFilter(apiKey: "test-only", transport: { _ in throw URLError(.cancelled) })
        do {
            _ = try await client.classify(utterance: "Open Search", taskContext: "", timing: timing)
            XCTFail("Returned a cancelled command")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(timing.report.contains("cancelled · Speech screening HTTP round trip"))
        XCTAssertFalse(timing.report.contains("Speech screening response parsing"))
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

    private func inputFields(_ request: URLRequest) throws -> [String: String] {
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        let text = try XCTUnwrap(content.first?["text"])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String])
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
