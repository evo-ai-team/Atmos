import Foundation
import XCTest
@testable import ChosenCore

final class OpenAIClientTests: XCTestCase {
    private let frame = ScreenshotFrame(data: Data([1, 2, 3]), width: 1280, height: 800, pointWidth: 1280, pointHeight: 800)
    private static let answer = #"{"id":"resp_done","status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"Done."}]}],"usage":{"input_tokens":42,"output_tokens":7}}"#

    func testBeginUsesStrictActionsAndOriginalScreenshot() async throws {
        let recorder = RequestRecorder()
        let client = OpenAIComputerClient(apiKey: "test-only-value", transport: { request in
            await recorder.add(request)
            return (Data(Self.answer.utf8), Self.response())
        })
        let turn = try await client.begin(command: "Open Calculator", frame: frame, context: "Finder is active")
        let requests = await recorder.requests
        let request = try XCTUnwrap(requests.first)
        let body = try json(request)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.timeoutInterval, 30)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer ") == true)
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(body["service_tier"] as? String, "fast")
        XCTAssertEqual(body["max_output_tokens"] as? Int, 2048)
        XCTAssertEqual(body["parallel_tool_calls"] as? Bool, false)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ["execute_actions", "pause_for_user"])
        for tool in tools {
            XCTAssertEqual(tool["type"] as? String, "function")
            XCTAssertEqual(tool["strict"] as? Bool, true)
            try assertClosedObjects(XCTUnwrap(tool["parameters"] as? [String: Any]))
        }
        let parameters = try XCTUnwrap(tools.first?["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
        XCTAssertEqual(Set(properties.keys), Set(["description", "actions"]))
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        XCTAssertEqual(actions["maxItems"] as? Int, 12)
        let items = try XCTUnwrap(actions["items"] as? [String: Any])
        let variants = try XCTUnwrap(items["anyOf"] as? [[String: Any]])
        XCTAssertEqual(variants.count, 9)
        XCTAssertNil(body["previous_response_id"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertTrue(content[0]["text"]?.contains("Open Calculator") == true)
        XCTAssertEqual(content[1], ["type": "input_image", "image_url": frame.dataURL, "detail": "original"])
        XCTAssertEqual(turn.message, "Done.")
        XCTAssertEqual(turn.inputTokens, 42)
        XCTAssertEqual(turn.outputTokens, 7)
    }

    func testContinuationReturnsScreenshotToMatchingFunctionCall() async throws {
        let recorder = RequestRecorder()
        let client = OpenAIComputerClient(apiKey: "test-only-value", model: "requested-model", serviceTier: "auto", transport: { request in
            await recorder.add(request)
            return (Data(Self.answer.utf8), Self.response())
        })
        _ = try await client.continueTurn(responseID: "resp_previous", outputs: [("call_1", frame)])
        let requests = await recorder.requests
        let body = try json(XCTUnwrap(requests.first))
        XCTAssertEqual(body["previous_response_id"] as? String, "resp_previous")
        XCTAssertEqual(body["model"] as? String, "requested-model")
        XCTAssertEqual(body["service_tier"] as? String, "auto")
        XCTAssertNotNil(body["instructions"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        let item = try XCTUnwrap(input.first)
        XCTAssertEqual(item["type"] as? String, "function_call_output")
        XCTAssertEqual(item["call_id"] as? String, "call_1")
        XCTAssertNil(item["acknowledged_safety_checks"])
        let output = try XCTUnwrap(item["output"] as? [[String: String]])
        XCTAssertEqual(output[0]["type"], "input_text")
        XCTAssertTrue(output[0]["text"]?.contains("1280 × 800") == true)
        XCTAssertEqual(output[1], ["type": "input_image", "image_url": frame.dataURL, "detail": "original"])
    }

    func testParsesDescriptionWithOrderedActions() throws {
        let turn = try OpenAIComputerClient.parseResponse(responseData([function([
            "description": "Searching Linus Tech Tips…",
            "actions": [
                ["type": "click", "button": "left", "x": 20.5, "y": 40, "keys": []],
                ["type": "type", "text": "Linus Tech Tips"],
                ["type": "keypress", "keys": ["ENTER"]]
            ]
        ])]))
        let call = try XCTUnwrap(turn.calls.first)
        XCTAssertEqual(call.callID, "call_1")
        XCTAssertEqual(call.description, "Searching Linus Tech Tips…")
        XCTAssertEqual(call.actions.map(\.type), ["click", "type", "keypress"])
        XCTAssertEqual(call.actions[0].x, 20.5)
        XCTAssertEqual(call.actions[1].text, "Linus Tech Tips")
        XCTAssertEqual(call.actions[2].keys, ["ENTER"])
        XCTAssertTrue(call.safetyChecks.isEmpty)
        XCTAssertNil(turn.pauseReason)
    }

    func testAllSupportedActionVariantsParse() throws {
        let actions: [[String: Any]] = [
            ["type": "click", "x": 10, "y": 20, "button": "right", "keys": ["SHIFT"]],
            ["type": "double_click", "x": 10, "y": 20, "button": "left", "keys": []],
            ["type": "move", "x": 10, "y": 20, "keys": []],
            ["type": "scroll", "x": 10, "y": 20, "scroll_x": 0, "scroll_y": 500, "keys": []],
            ["type": "drag", "path": [["x": 1, "y": 2], ["x": 3, "y": 4]], "keys": ["CMD"]],
            ["type": "type", "text": "hello\nworld\t!"],
            ["type": "keypress", "keys": ["CMD", "SHIFT", "L"]],
            ["type": "wait"], ["type": "screenshot"]
        ]
        let turn = try OpenAIComputerClient.parseResponse(responseData([function(["description": "Checking the current page…", "actions": actions])]))
        XCTAssertEqual(turn.calls.first?.actions.count, 9)
        XCTAssertEqual(turn.calls.first?.actions[4].path, [ActionPoint(x: 1, y: 2), ActionPoint(x: 3, y: 4)])
    }

    func testPauseReturnsReasonWithoutExecutableActions() throws {
        let turn = try OpenAIComputerClient.parseResponse(responseData([function(["reason": "Which channel should I open?"], name: "pause_for_user")]))
        XCTAssertEqual(turn.pauseReason, "Which channel should I open?")
        XCTAssertTrue(turn.calls.isEmpty)
    }

    func testRejectsMalformedDescriptionsAndBatches() throws {
        let payloads: [[String: Any]] = [
            ["actions": [["type": "wait"]]],
            ["description": "", "actions": [["type": "wait"]]],
            ["description": "   ", "actions": [["type": "wait"]]],
            ["description": "Opening\nYouTube…", "actions": [["type": "wait"]]],
            ["description": String(repeating: "x", count: 65), "actions": [["type": "wait"]]],
            ["description": 42, "actions": [["type": "wait"]]],
            ["description": "Opening YouTube…", "actions": []],
            ["description": "Opening YouTube…", "actions": Array(repeating: ["type": "wait"], count: 13)],
            ["description": "Opening YouTube…", "actions": [["type": "wait"]], "script": "private-action-text"]
        ]
        for payload in payloads {
            try assertBlocked([function(payload)])
        }
    }

    func testRejectsUnknownFieldsMissingValuesAndInvalidActionParameters() throws {
        let actions: [[String: Any]] = [
            ["type": "exec", "text": "private-action-text"],
            ["type": "click", "x": 10, "y": 20, "keys": []],
            ["type": "click", "x": true, "y": 20, "button": "left", "keys": []],
            ["type": "click", "x": -1, "y": 20, "button": "left", "keys": []],
            ["type": "click", "x": NSNull(), "y": 20, "button": "left", "keys": []],
            ["type": "click", "x": 10, "y": 20, "button": "invalid", "keys": []],
            ["type": "move", "x": 10, "y": 20, "keys": ["ENTER"]],
            ["type": "scroll", "x": 10, "y": 20, "scroll_x": 0, "scroll_y": 100_001, "keys": []],
            ["type": "drag", "path": [["x": 1, "y": 2]], "keys": []],
            ["type": "drag", "path": [["x": 1, "y": 2, "text": "private-action-text"], ["x": 3, "y": 4]], "keys": []],
            ["type": "type", "text": "hello", "keys": ["CMD"]],
            ["type": "type", "text": ""],
            ["type": "type", "text": "\u{1B}"],
            ["type": "keypress", "keys": []],
            ["type": "keypress", "keys": ["CMD", "CMD", "L"]],
            ["type": "keypress", "keys": ["L", "K"]],
            ["type": "wait", "duration": 100],
            ["type": "screenshot", "x": 1]
        ]
        for action in actions {
            try assertBlocked([function(["description": "Opening YouTube…", "actions": [action]])])
        }
    }

    func testRejectsMultipleCallsPauseMixedWithActionsAndFinalMessageMixedWithActions() throws {
        let action = try function(["description": "Opening YouTube…", "actions": [["type": "wait"]]])
        let pause = try function(["reason": "Please confirm."], name: "pause_for_user", callID: "call_2")
        let secondAction = try function(["description": "Opening channel…", "actions": [["type": "wait"]]], callID: "call_2")
        let final: [String: Any] = ["type": "message", "content": [["type": "output_text", "text": "Done."]]]
        for output in [[action, pause], [pause, action], [action, secondAction], [action, final]] {
            try assertBlocked(output)
        }
    }

    func testRejectsInvalidFunctionCallsAndPauseArguments() throws {
        let valid = try function(["description": "Opening YouTube…", "actions": [["type": "wait"]]])
        var noID = valid; noID.removeValue(forKey: "call_id")
        var emptyID = valid; emptyID["call_id"] = ""
        var unknownFunction = valid; unknownFunction["name"] = "unexpected"
        var malformedArguments = valid; malformedArguments["arguments"] = "private-invalid-json"
        var objectArguments = valid; objectArguments["arguments"] = ["description": "Opening YouTube…"]
        for item in [noID, emptyID, unknownFunction, malformedArguments, objectArguments] { try assertBlocked([item]) }
        for payload in [["reason": ""], ["reason": "One\nTwo"], ["reason": "Confirm?", "actions": []]] as [[String: Any]] {
            try assertBlocked([function(payload, name: "pause_for_user")])
        }
    }

    func testBlocksIncompleteFailedRefusedAndUnsupportedResponses() throws {
        let fixtures = [
            #"{"id":"r","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#,
            #"{"id":"r","status":"failed","error":{"message":"private-server-text"},"output":[]}"#,
            #"{"id":"r","status":"in_progress","output":[]}"#,
            #"{"id":"r","status":"cancelled","output":[]}"#,
            #"{"id":"r","status":"queued","output":[]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"function_call","status":"incomplete"}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"I cannot do that."}]}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"computer_call","call_id":"c","actions":[{"type":"wait"}]}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"message","phase":"commentary","content":[{"type":"output_text","text":"Working on it."}]}]}"#,
            #"{"id":"r","status":"completed","output":[]}"#,
            "not json"
        ]
        for fixture in fixtures {
            XCTAssertThrowsError(try OpenAIComputerClient.parseResponse(Data(fixture.utf8))) { error in
                XCTAssertTrue(error is ChosenError)
                XCTAssertFalse(error.localizedDescription.contains("private-"))
            }
        }
        let action = try function(["description": "Opening YouTube…", "actions": [["type": "wait"]]])
        try assertBlocked([action, ["type": "message", "content": [["type": "refusal"]]]])
    }

    func testInvalidContinuationNeverUsesTransport() async throws {
        let recorder = RequestRecorder()
        let client = OpenAIComputerClient(apiKey: "test-only-value", transport: { request in
            await recorder.add(request)
            return (Data(Self.answer.utf8), Self.response())
        })
        for outputs in [[(callID: "", frame: frame)], [(callID: "same", frame: frame), (callID: "same", frame: frame)]] {
            do {
                _ = try await client.continueTurn(responseID: "resp_previous", outputs: outputs)
                XCTFail("Expected invalid continuation")
            } catch { XCTAssertTrue(error is ChosenError) }
        }
        let requests = await recorder.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testHTTPErrorIsSanitizedAndNeverRetried() async {
        let recorder = RequestRecorder()
        let client = OpenAIComputerClient(apiKey: "test-only-value", transport: { request in
            await recorder.add(request)
            return (Data(#"{"error":{"message":"private request contents"}}"#.utf8), Self.response(status: 429))
        })
        do {
            _ = try await client.begin(command: "Open Calculator", frame: frame, context: "")
            XCTFail("Expected a rate-limit error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("limit"))
            XCTAssertFalse(error.localizedDescription.contains("private"))
        }
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testTimeoutAndCancellationDoNotRetry() async {
        for code: URLError.Code in [.timedOut, .cancelled] {
            let recorder = RequestRecorder()
            let client = OpenAIComputerClient(apiKey: "test-only-value", transport: { request in
                await recorder.add(request)
                throw URLError(code)
            })
            do {
                _ = try await client.begin(command: "Open Calculator", frame: frame, context: "")
                XCTFail("Expected transport error")
            } catch {
                if code == .cancelled { XCTAssertTrue(error is CancellationError) }
                else { XCTAssertTrue(error.localizedDescription.contains("30 seconds")) }
            }
            let requests = await recorder.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    private func assertBlocked(_ output: [[String: Any]], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertThrowsError(try OpenAIComputerClient.parseResponse(responseData(output)), file: file, line: line) { error in
            XCTAssertTrue(error is ChosenError, file: file, line: line)
            XCTAssertTrue(error.localizedDescription.contains("No new actions were executed."), file: file, line: line)
            XCTAssertFalse(error.localizedDescription.contains("private-"), file: file, line: line)
        }
    }
    private func function(_ arguments: [String: Any], name: String = "execute_actions", callID: String = "call_1") throws -> [String: Any] {
        ["type": "function_call", "status": "completed", "name": name, "call_id": callID,
         "arguments": String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)]
    }
    private func responseData(_ output: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["id": "resp_1", "status": "completed", "output": output])
    }
    private func assertClosedObjects(_ schema: [String: Any]) throws {
        if schema["type"] as? String == "object" {
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertEqual(Set(schema["required"] as? [String] ?? []), Set(properties.keys))
            for value in properties.values {
                try assertClosedObjects(XCTUnwrap(value as? [String: Any]))
            }
        }
        if let items = schema["items"] as? [String: Any] { try assertClosedObjects(items) }
        for variant in schema["anyOf"] as? [[String: Any]] ?? [] { try assertClosedObjects(variant) }
    }
    private func json(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
    }
    private static func response(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.openai.com/v1/responses")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}

private actor RequestRecorder {
    var requests: [URLRequest] = []
    func add(_ request: URLRequest) { requests.append(request) }
}
