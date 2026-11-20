import Foundation
import XCTest
@testable import AtmosCore

final class LunaAccessibilityTests: XCTestCase {
    private let frame = ScreenshotFrame(data: Data([1]), width: 800, height: 600, pointWidth: 800, pointHeight: 600)

    private func snapshot() -> AccessibilitySnapshot {
        AccessibilitySnapshot(processID: 123, elements: [
            AccessibilityElement(id: "e7", role: "AXButton", label: "Main menu", enabled: true,
                                 actions: AccessibilityAction.supportedActions,
                                 screenshotBounds: .init(x: 20, y: 30, width: 40, height: 40))
        ])
    }

    private func arguments(_ tree: AccessibilitySnapshot, action: String = "AXPress") -> [String: Any] {
        ["snapshot_id": tree.id.uuidString, "element_id": "e7", "action": action,
         "description": "Opening Menu", "task_update": ["kind": "replace", "goal": "Open the main menu."]]
    }

    private func response(_ arguments: [String: Any], name: String = "perform_accessibility_action") throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "id": "resp_ax", "status": "completed", "output": [[
                "type": "function_call", "status": "completed", "call_id": "call_ax", "name": name,
                "arguments": String(decoding: JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
            ]]
        ])
    }

    private func client(reply: Data, inspect: @escaping (URLRequest) throws -> Void = { _ in }) -> OpenAIComputerClient {
        OpenAIComputerClient(apiKey: "test-only-value", transport: { request in
            try inspect(request)
            return (reply, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
    }

    func testCurrentTreeEnablesNativeToolAndPreservesExactActionInHistory() async throws {
        let tree = snapshot()
        for action in AccessibilityAction.supportedActions {
            let client = client(reply: try response(arguments(tree, action: action))) { request in
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
                let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
                let tool = try XCTUnwrap(tools.first { $0["name"] as? String == "perform_accessibility_action" })
                XCTAssertEqual(tool["strict"] as? Bool, true)
                let parameters = try XCTUnwrap(tool["parameters"] as? [String: Any])
                let properties = try XCTUnwrap(parameters["properties"] as? [String: Any])
                XCTAssertEqual(parameters["additionalProperties"] as? Bool, false)
                XCTAssertEqual(Set(parameters["required"] as? [String] ?? []), Set(properties.keys))
                let input = try XCTUnwrap(body["input"] as? [[String: Any]])
                let content = try XCTUnwrap(input[0]["content"] as? [[String: String]])
                XCTAssertTrue(content[0]["text"]?.contains(tree.contextText) == true)
                XCTAssertEqual(content[1]["type"], "input_image")
                XCTAssertTrue(tools.contains { $0["name"] as? String == "execute_actions" })
                XCTAssertTrue(tools.contains { $0["name"] as? String == "complete_task" })
            }
            let turn = try await client.begin(command: "Open the main menu", frame: frame, context: "", accessibility: tree)
            let call = try XCTUnwrap(turn.calls.first)
            let input = try XCTUnwrap(call.actions.first)
            let target = try XCTUnwrap(input.accessibility)
            XCTAssertEqual(turn.calls.count, 1)
            XCTAssertEqual(call.actions.count, 1)
            XCTAssertEqual(try target.resolve(in: tree), tree.elements[0])
            XCTAssertEqual(target.action, action)
            XCTAssertEqual(ActionDispatchSummary.batch(call.actions), "\(action) e7")
            var history = TaskSteeringState(command: "Open the main menu")
            let id = history.beginAction(action: input, description: call.description)
            history.finishAction(id: id)
            XCTAssertTrue(history.contextText.contains(tree.id.uuidString))
            XCTAssertTrue(history.contextText.contains("\"element_id\":\"e7\""))
            XCTAssertTrue(history.contextText.contains("\"action\":\"\(action)\""))
        }
    }

    func testRejectsWrongSnapshotUnknownElementAndUnexposedAction() async throws {
        let tree = snapshot()
        var foreign = arguments(tree); foreign["snapshot_id"] = UUID().uuidString
        var unknown = arguments(tree); unknown["element_id"] = "e999"
        var treeWithPressOnly = tree; treeWithPressOnly.elements[0].actions = ["AXPress"]
        for payload in [foreign, unknown, arguments(tree, action: "AXShowMenu")] {
            do {
                _ = try await client(reply: response(payload)).begin(command: "Open menu", frame: frame, context: "", accessibility: treeWithPressOnly)
                XCTFail("A mismatched target must not reach dispatch")
            } catch let error as AtmosError {
                guard case .invalidAction = error else { return XCTFail("Unexpected error: \(error)") }
            }
        }
    }

    func testUnavailableDisabledHiddenSecureAndAmbiguousTargetsAreRejected() throws {
        let original = snapshot()
        let action = AccessibilityAction(snapshotID: original.id, elementID: "e7", action: "AXPress")
        let changes: [(inout AccessibilitySnapshot) -> Void] = [
            { $0.unavailableReason = "No permission" },
            { $0.elements[0].enabled = false }, { $0.elements[0].enabled = nil },
            { $0.elements[0].secure = true }, { $0.elements[0].subrole = "AXSecureTextField" },
            { $0.elements[0].role = "AXSecureTextField" },
            { $0.elements[0].screenshotBounds = nil },
            { $0.elements[0].screenshotBounds?.x = -1 },
            { $0.elements[0].screenshotBounds?.width = 0 },
            { $0.elements.append($0.elements[0]) },
            { $0.elements[0].actions = ["AXSetValue"] }
        ]
        for change in changes {
            var tree = original; change(&tree)
            XCTAssertThrowsError(try action.resolve(in: tree))
            XCTAssertFalse(ComputerRequestPolicy(accessibility: tree).tools.contains {
                $0["name"] as? String == "perform_accessibility_action"
            })
        }
        var partial = original; partial.truncated = true
        XCTAssertEqual(try action.resolve(in: partial).id, "e7", "A partial tree still has usable captured controls")
    }

    func testRejectsMalformedNativeToolAndNativeActionsInsideCoordinateBatch() throws {
        let tree = snapshot()
        var invalidAction = arguments(tree); invalidAction["action"] = "AXSetValue"
        var invalidID = arguments(tree); invalidID["snapshot_id"] = "old-snapshot"
        var emptyID = arguments(tree); emptyID["element_id"] = ""
        var noGoal = arguments(tree); noGoal.removeValue(forKey: "task_update")
        var extra = arguments(tree); extra["x"] = 40
        for payload in [invalidAction, invalidID, emptyID, noGoal, extra] {
            XCTAssertThrowsError(try OpenAIComputerClient.parseResponse(response(payload)))
        }
        let batch: [String: Any] = [
            "description": "Opening Menu", "task_update": ["kind": "replace", "goal": "Open menu"],
            "actions": [["type": "accessibility", "snapshot_id": tree.id.uuidString, "element_id": "e7", "action": "AXPress"]]
        ]
        XCTAssertThrowsError(try OpenAIComputerClient.parseResponse(response(batch, name: "execute_actions")))
    }

    func testReviewAndImageOnlyContinuationCannotExecuteNativeTargets() async throws {
        let tree = snapshot()
        let reply = try response(arguments(tree))
        let client = client(reply: reply) { request in
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
            XCTAssertFalse(tools.contains { $0["name"] as? String == "perform_accessibility_action" })
        }
        do {
            _ = try await client.begin(command: "Open menu", frame: frame, context: "", accessibility: tree, reviewRequired: true)
            XCTFail("Review must not execute AX actions")
        } catch is AtmosError {}
        do {
            _ = try await client.continueTurn(responseID: "previous", outputs: [("call_previous", frame)])
            XCTFail("An image-only continuation cannot reuse a previous tree")
        } catch is AtmosError {}
        do {
            _ = try await client.begin(command: "Open menu", frame: frame, context: "")
            XCTFail("No snapshot means no native action")
        } catch is AtmosError {}
    }

    func testFreshAcceptedTaskContinuationCanUseNativeAction() async throws {
        let tree = snapshot()
        var payload = arguments(tree)
        payload["task_update"] = ["kind": "revise", "goal": "Open the main menu."]
        let turn = try await client(reply: response(payload)).begin(command: "Open the main menu", frame: frame, context: "",
            activeTask: "Menu still closed", accessibility: tree, continuingTask: true)
        XCTAssertEqual(turn.taskUpdate?.kind, .revise)
        XCTAssertEqual(turn.calls.first?.actions.first?.accessibility?.elementID, "e7")
    }
}
