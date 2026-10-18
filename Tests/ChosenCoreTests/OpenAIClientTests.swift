import Foundation
import XCTest
@testable import ChosenCore

final class OpenAIClientTests: XCTestCase {
    private let frame = ScreenshotFrame(data: Data([1, 2, 3]), width: 1280, height: 800, pointWidth: 1280, pointHeight: 800)
    private static let answer = #"{"id":"resp_done","status":"completed","output":[{"type":"message","status":"completed","content":[{"type":"output_text","text":"Done."}]}],"usage":{"input_tokens":42,"output_tokens":7}}"#

    func testBeginUsesNativeComputerToolAndOriginalScreenshot() async throws {
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
        XCTAssertEqual(body["max_output_tokens"] as? Int, 1024)
        XCTAssertEqual((body["reasoning"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(body["tools"] as? [[String: String]], [["type": "computer"]])
        XCTAssertNil(body["previous_response_id"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input.first?["content"] as? [[String: String]])
        XCTAssertTrue(content[0]["text"]?.contains("Open Calculator") == true)
        XCTAssertEqual(content[1], ["type": "input_image", "image_url": frame.dataURL, "detail": "original"])
        XCTAssertEqual(turn.message, "Done.")
        XCTAssertEqual(turn.inputTokens, 42)
        XCTAssertEqual(turn.outputTokens, 7)
    }

    func testContinuationPreservesCallIDsAndDoesNotAcknowledgeSafetyChecks() async throws {
        let recorder = RequestRecorder()
        let client = OpenAIComputerClient(apiKey: "test-only-value", model: "requested-model", serviceTier: "auto", transport: { request in
            await recorder.add(request)
            return (Data(Self.answer.utf8), Self.response())
        })
        _ = try await client.continueTurn(responseID: "resp_previous", outputs: [("call_1", frame), ("call_2", frame)])
        let requests = await recorder.requests
        let body = try json(XCTUnwrap(requests.first))
        XCTAssertEqual(body["previous_response_id"] as? String, "resp_previous")
        XCTAssertEqual(body["model"] as? String, "requested-model")
        XCTAssertEqual(body["service_tier"] as? String, "auto")
        XCTAssertNotNil(body["instructions"])
        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        XCTAssertEqual(input.compactMap { $0["call_id"] as? String }, ["call_1", "call_2"])
        for item in input {
            XCTAssertEqual(item["type"] as? String, "computer_call_output")
            XCTAssertNil(item["acknowledged_safety_checks"])
            XCTAssertEqual(item["output"] as? [String: String], ["type": "computer_screenshot", "image_url": frame.dataURL, "detail": "original"])
        }
    }

    func testParsesOrderedActionsAndPendingSafetyChecks() throws {
        let data = Data(#"{"id":"resp_1","status":"completed","output":[{"type":"reasoning","summary":[]},{"type":"computer_call","call_id":"call_1","status":"completed","actions":[{"type":"click","button":"left","x":20.5,"y":40},{"type":"type","text":"hello"},{"type":"scroll","x":20,"y":40,"scroll_x":0,"scroll_y":500},{"type":"drag","path":[{"x":1,"y":2},{"x":3,"y":4}]}],"pending_safety_checks":[{"id":"check_1","code":"review","message":"Confirm this action."},{"id":"check_2","code":"human_review"},{"id":"check_3"}]}]}"#.utf8)
        let turn = try OpenAIComputerClient.parseResponse(data)
        let call = try XCTUnwrap(turn.calls.first)
        XCTAssertEqual(call.callID, "call_1")
        XCTAssertEqual(call.actions.map(\.type), ["click", "type", "scroll", "drag"])
        XCTAssertEqual(call.actions[0].x, 20.5)
        XCTAssertEqual(call.actions[1].text, "hello")
        XCTAssertEqual(call.actions[2].scrollY, 500)
        XCTAssertEqual(call.actions[3].path, [ActionPoint(x: 1, y: 2), ActionPoint(x: 3, y: 4)])
        XCTAssertEqual(call.safetyChecks.count, 3)
        XCTAssertEqual(call.safetyChecks.first, "Confirm this action.")
        XCTAssertEqual(call.safetyChecks[1], "human_review")
    }

    func testSupportsLegacySingleAction() throws {
        let data = Data(#"{"id":"resp_1","status":"completed","output":[{"type":"computer_call","call_id":"call_1","action":{"type":"screenshot"}}]}"#.utf8)
        let turn = try OpenAIComputerClient.parseResponse(data)
        XCTAssertEqual(turn.calls.first?.actions, [ComputerAction(type: "screenshot")])
    }

    func testInvalidComputerCallsReportOnlyStructuralMetadata() throws {
        let fixtures: [(String, String)] = [
            (#"[{"type":"computer_call","actions":[{"type":"type","text":"private-action-text"}]}]"#, "missing or null call_id"),
            (#"[{"type":"computer_call","call_id":"","actions":[{"type":"screenshot"}]}]"#, "empty call_id"),
            (#"[{"type":"computer_call","call_id":"private-call-id","actions":[]}]"#, "empty actions array (legacy action present: false)"),
            (#"[{"type":"computer_call","call_id":"private-call-id","actions":[],"action":{"type":"screenshot"}}]"#, "empty actions array (legacy action present: true)"),
            (#"[{"type":"computer_call","call_id":"private-call-id"}]"#, "no actions array or legacy action"),
            (#"[{"type":"computer_call","call_id":"private-call-id","actions":[{"type":"screenshot"}]},{"type":"computer_call","call_id":"private-call-id","actions":[{"type":"screenshot"}]}]"#, "output index 1 repeats a call_id")
        ]
        for (output, diagnostic) in fixtures {
            let data = Data("{\"id\":\"private-response-id\",\"status\":\"completed\",\"output\":\(output)}".utf8)
            XCTAssertThrowsError(try OpenAIComputerClient.parseResponse(data)) { error in
                XCTAssertTrue(error.localizedDescription.contains(diagnostic))
                XCTAssertFalse(error.localizedDescription.contains("private-"))
            }
        }
    }

    func testBlocksIncompleteFailedRefusedAndMalformedResponses() {
        let fixtures = [
            #"{"id":"r","status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[{"type":"computer_call","call_id":"c","actions":[{"type":"click","x":1,"y":2}]}]}"#,
            #"{"id":"r","status":"failed","error":{"message":"sensitive server text"},"output":[]}"#,
            #"{"id":"r","status":"in_progress","output":[]}"#,
            #"{"id":"r","status":"cancelled","output":[]}"#,
            #"{"id":"r","status":"queued","output":[]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"computer_call","call_id":"c","status":"incomplete","actions":[{"type":"wait"}]}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"computer_call","call_id":"c","actions":[{"type":"wait"}]},{"type":"message","content":[{"type":"refusal","refusal":"I cannot do that."}]}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"computer_call","call_id":"c","actions":[{"type":"exec"}]}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"computer_call","call_id":"c","actions":[]}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"function_call","name":"unexpected"}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"message","phase":"commentary","content":[{"type":"output_text","text":"Working on it."}]}]}"#,
            #"{"id":"r","status":"completed","output":[{"type":"computer_call","call_id":"c","actions":[{"type":"wait"}]},{"type":"computer_call","call_id":"c","actions":[{"type":"wait"}]}]}"#,
            #"{"id":"r","status":"completed","output":[]}"#,
            "not json"
        ]
        for fixture in fixtures {
            XCTAssertThrowsError(try OpenAIComputerClient.parseResponse(Data(fixture.utf8))) { error in
                XCTAssertTrue(error is ChosenError)
                XCTAssertFalse(error.localizedDescription.contains("sensitive server text"))
            }
        }
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
