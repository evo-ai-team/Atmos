import Foundation
import XCTest
@testable import MouseCore

/// Exercises the projection, wire request, and local action lookup together.
/// The injected transport never sends a request or operates the desktop.
final class CompactDecisionsRequestTests: XCTestCase {
    func testTextOnlyChoiceRoundTripRetainsExactNativeTargetLocally() async throws {
        let target = AccessibilityElement(
            id: "local-element-identity", role: "AXButton", label: "Home",
            help: "unneeded-help-text", enabled: true, actions: ["AXPress", "AXShowMenu"],
            screenBounds: AccessibilityBounds(x: 700, y: 200, width: 80, height: 30),
            screenshotBounds: AccessibilityBounds(x: 10, y: 20, width: 80, height: 30)
        )
        let snapshot = AccessibilitySnapshot(processID: 7, elements: [target])
        let context = ComputerDecisionContext(
            request: "Click Home", isContinuation: false, task: nil,
            recentCommands: [], pendingClarification: nil, snapshot: snapshot
        )
        let options = ComputerDecisionOptions(snapshot: snapshot, allowNativeActions: true,
                                              allowCompletion: context.hasUIEvidence)
        let choice = try XCTUnwrap(options.nativeOptions.first)
        XCTAssertEqual(choice.description, "Click \"Home\" (button)")
        XCTAssertNotNil(Int(choice.value))
        let question = try XCTUnwrap(options.questions.first)
        let reply = try JSONSerialization.data(withJSONObject: [
            "model": "gpt-6-luna",
            "answers": [[
                "type": "choice", "name": question.name, "choice": choice.value, "confidence": 1.0,
                "probabilities": question.choices.map {
                    ["value": $0.value, "probability": $0.value == choice.value ? 1.0 : 0.0] as [String: Any]
                }
            ]],
            "usage": ["input_tokens": 100, "output_tokens": 0]
        ])
        let recorder = RequestRecorder()
        let client = DecisionsClient(apiKey: "offline-test", transport: { request in
            await recorder.record(request)
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200,
                                          httpVersion: "HTTP/2", headerFields: nil)!)
        })
        let contextText = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        let result = try await client.decide(instructions: ComputerDecisionOptions.instructions,
                                            context: contextText, questions: options.questions)
        let decision = try options.resolve(result)
        guard case let .native(element, action, description) = decision else {
            return XCTFail("Expected the offered native action")
        }
        XCTAssertEqual(element, target)
        XCTAssertEqual(action, "AXPress")
        XCTAssertEqual(description, "Clicking Home…")

        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 1)
        let data = try XCTUnwrap(requests.first?.httpBody)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(body["input"] as? [[String: Any]])
        for message in messages {
            let parts = try XCTUnwrap(message["content"] as? [[String: String]])
            XCTAssertEqual(parts.count, 1)
            XCTAssertEqual(Set(parts[0].keys), ["type", "text"])
            XCTAssertEqual(parts[0]["type"], "input_text")
        }
        let requestText = String(decoding: data, as: UTF8.self)
        for localOnly in ["local-element-identity", "unneeded-help-text", "screenBounds",
                          "screenshotBounds", "image_url", "input_image", "data:image/"] {
            XCTAssertFalse(requestText.contains(localOnly), localOnly)
        }
        XCTAssertTrue(requestText.contains("Click Home"))
        // Excluding metadata on the wire must not strip the locally retained
        // geometry or exact semantic action needed for native revalidation.
        XCTAssertEqual(element.screenBounds, target.screenBounds)
    }

    private actor RequestRecorder {
        var requests: [URLRequest] = []
        func record(_ request: URLRequest) { requests.append(request) }
    }
}
