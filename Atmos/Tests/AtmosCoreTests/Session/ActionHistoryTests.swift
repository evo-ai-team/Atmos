import XCTest
@testable import AtmosCore

final class ActionHistoryTests: XCTestCase {
    func testDescriptionAndExactPayloadRemainSeparateInChronologicalHistory() throws {
        var history = ActionHistory()
        let executionID = UUID(), clickID = UUID(), typeID = UUID()
        let startedAt = Date()
        let click = ComputerAction(type: "click", x: 125.5, y: 99, button: "right")
        let typed = ComputerAction(type: "type", text: "Exact \"quoted\" input\nhttps://example.com/🐭")
        history.begin(id: clickID, executionID: executionID, goal: "Open the menu", source: "Luna",
                      description: "Selecting the menu", action: click)
        history.begin(id: typeID, executionID: executionID, goal: "Enter the text", source: "Luna",
                      description: "Typing the requested text", action: typed)

        XCTAssertEqual(history.entries.map(\.id), [clickID, typeID])
        XCTAssertEqual(history.entries.map(\.goal), ["Open the menu", "Enter the text"])
        XCTAssertEqual(history.entries.map(\.source), ["Luna", "Luna"])
        XCTAssertEqual(history.entries.map(\.description), ["Selecting the menu", "Typing the requested text"])
        XCTAssertEqual(try action(in: history.entries[0]), click)
        XCTAssertEqual(try action(in: history.entries[1]), typed)
        XCTAssertTrue(history.entries[0].payloadJSON.contains("\n"))
        XCTAssertFalse(history.entries[0].payloadJSON.contains("Selecting the menu"))
        for entry in history.entries {
            XCTAssertEqual(entry.status.rawValue, "Dispatching")
            XCTAssertNil(entry.detail)
            XCTAssertGreaterThanOrEqual(entry.recordedAt, startedAt)
            XCTAssertLessThanOrEqual(entry.recordedAt, Date())
        }
    }

    func testObservationAndWaitActionsAreNotOmitted() throws {
        var history = ActionHistory()
        let executionID = UUID()
        for type in ["screenshot", "wait"] {
            let id = UUID()
            history.begin(id: id, executionID: executionID, goal: "Check the page", source: "Luna",
                          description: "Reviewing", action: ComputerAction(type: type))
            history.finish(id: id)
        }

        XCTAssertEqual(try history.entries.map { try action(in: $0).type }, ["screenshot", "wait"])
        XCTAssertEqual(history.entries.map(\.status.rawValue), ["Dispatched", "Dispatched"])
    }

    func testDispatchFailureKeepsDetailAndCannotBeCompletedByLateReturn() {
        var history = ActionHistory()
        let id = UUID()
        history.begin(id: id, executionID: UUID(), goal: "Type text", source: "Luna",
                      description: "Typing", action: ComputerAction(type: "type", text: "hello"))
        history.markUncertain(id: id, detail: "Input stopped after two characters.")
        let interrupted = history.entries
        history.finish(id: id)
        history.markUncertain(id: id, detail: "A later error must not erase the original.")

        XCTAssertEqual(history.entries, interrupted)
        XCTAssertEqual(history.entries[0].status.rawValue, "Uncertain")
        XCTAssertEqual(history.entries[0].detail, "Input stopped after two characters.")
    }

    func testCancellationTouchesOnlyUnfinishedActionsInItsOwnExecution() {
        var history = ActionHistory()
        let oldExecution = UUID(), newExecution = UUID()
        let completedID = UUID(), interruptedID = UUID(), currentID = UUID()
        for (id, executionID) in [(completedID, oldExecution), (interruptedID, oldExecution), (currentID, newExecution)] {
            history.begin(id: id, executionID: executionID, goal: "Move the cursor", source: "Luna",
                          description: "Moving", action: ComputerAction(type: "move", x: 20, y: 30))
        }
        history.finish(id: completedID)
        history.markUnfinishedUncertain(executionID: oldExecution)
        history.finish(id: interruptedID)

        XCTAssertEqual(history.entries.map(\.status), [.dispatched, .uncertain, .dispatching])
        XCTAssertNotNil(history.entries[1].detail)
        XCTAssertNil(history.entries[0].detail)
        XCTAssertNil(history.entries[2].detail)
        history.finish(id: currentID)
        XCTAssertEqual(history.entries.map(\.status), [.dispatched, .uncertain, .dispatched])
    }

    func testUnknownAndRepeatedTransitionsDoNotChangeFinishedRows() {
        var history = ActionHistory()
        let id = UUID()
        history.begin(id: id, executionID: UUID(), goal: "Open Home", source: "Luna",
                      description: "Opening Home", action: ComputerAction(type: "click", x: 20, y: 30))
        history.finish(id: id)
        let finished = history.entries
        history.finish(id: id)
        history.finish(id: UUID())
        history.markUncertain(id: id, detail: "Too late")
        history.markUncertain(id: UUID(), detail: "Unknown")
        history.markUnfinishedUncertain(executionID: UUID())

        XCTAssertEqual(history.entries, finished)
    }

    func testNativePayloadPreservesAccessibilityOperationInsteadOfCoordinatePlaceholder() throws {
        var history = ActionHistory()
        let snapshotID = UUID()
        history.begin(
            id: UUID(), executionID: UUID(), goal: "Open Home", source: "Decisions",
            description: "Opening Home", action: ComputerAction(type: "click", x: 30, y: 40),
            nativeTarget: ActionHistory.NativeTarget(
                action: "AXPress", elementID: "element-2", snapshotID: snapshotID, role: "AXButton",
                label: "Home", screenBounds: AccessibilityBounds(x: 20, y: 30, width: 100, height: 40)
            )
        )
        let data = Data(history.entries[0].payloadJSON.utf8)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["action"] as? String, "AXPress")
        XCTAssertEqual(payload["elementID"] as? String, "element-2")
        XCTAssertEqual(payload["snapshotID"] as? String, snapshotID.uuidString)
        XCTAssertEqual(payload["role"] as? String, "AXButton")
        XCTAssertEqual(payload["label"] as? String, "Home")
        XCTAssertEqual(payload["screenBounds"] as? [String: Double], ["x": 20, "y": 30, "width": 100, "height": 40])
        XCTAssertNil(payload["type"])
        XCTAssertNil(payload["x"])
        XCTAssertNil(payload["y"])
    }

    func testInvalidCoordinatesRemainInspectableWithoutBreakingHistory() throws {
        var history = ActionHistory()
        history.begin(id: UUID(), executionID: UUID(), goal: "Move the cursor", source: "Luna",
                      description: "Moving", action: ComputerAction(type: "move", x: .nan, y: .infinity))
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let decoded = try decoder.decode(ComputerAction.self, from: Data(history.entries[0].payloadJSON.utf8))

        XCTAssertTrue(try XCTUnwrap(decoded.x).isNaN)
        XCTAssertEqual(decoded.y, .infinity)
    }

    private func action(in entry: ActionHistory.Entry) throws -> ComputerAction {
        try JSONDecoder().decode(ComputerAction.self, from: Data(entry.payloadJSON.utf8))
    }
}
