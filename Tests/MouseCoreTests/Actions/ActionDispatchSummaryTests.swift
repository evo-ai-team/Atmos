import XCTest
@testable import MouseCore

final class ActionDispatchSummaryTests: XCTestCase {
    func testDistinguishesObservationOnlyFromRealInput() {
        XCTAssertEqual(ActionDispatchSummary.batch([.init(type: "screenshot"), .init(type: "wait")]),
                       "screenshot (no input) → wait (no input)")
        let click = ActionDispatchSummary.batch([.init(type: "click", x: 150, y: 205.5, button: "right")])
        XCTAssertEqual(click, "click right (150, 205.5)")
        XCTAssertFalse(click.contains("no input"))
        XCTAssertEqual(ActionDispatchSummary.batch([]), "no actions")
    }

    func testTypingNeverIncludesItsContent() {
        let privateText = "private password\n👩🏽‍💻"
        let summary = ActionDispatchSummary.batch([.init(type: "type", text: privateText)])
        XCTAssertEqual(summary, "type \(privateText.count) characters")
        XCTAssertFalse(summary.contains("private"))
        XCTAssertFalse(summary.contains("password"))
        XCTAssertFalse(summary.contains("👩"))
    }

    func testShortcutsRemainUsefulWithoutRevealingTypedCharacters() {
        let actions: [ComputerAction] = [
            .init(type: "keypress", keys: ["command", "l"]),
            .init(type: "keypress", keys: ["CMD", "TAB"]),
            .init(type: "keypress", keys: ["a"]),
            .init(type: "keypress", keys: ["SHIFT", "b"]),
            .init(type: "keypress", keys: ["ALT", "c"]),
            .init(type: "keypress", keys: ["CTRL", "ArrowLeft"])
        ]
        XCTAssertEqual(ActionDispatchSummary.batch(actions),
                       "keypress CMD+L → keypress CMD+TAB → keypress <character> → keypress SHIFT+<character> → keypress ALT+<character> → keypress CTRL+LEFT")
        let malformed = ActionDispatchSummary.batch([
            .init(type: "keypress", keys: ["private credential"]),
            .init(type: "private content", text: "private content"),
            .init(type: "click", x: .nan, y: .infinity, button: "private content")
        ])
        XCTAssertFalse(malformed.contains("private"))
        XCTAssertTrue(malformed.contains("unsupported action"))
        XCTAssertTrue(malformed.contains("(?, ?)"))
    }

    func testPointerActionsIncludeParametersAndPreserveBatchOrder() {
        let actions: [ComputerAction] = [
            .init(type: "move", x: 20, y: 30),
            .init(type: "double_click", x: 40, y: 50, keys: ["SHIFT"]),
            .init(type: "scroll", x: 100, y: 200, scrollX: -10, scrollY: 600),
            .init(type: "drag", keys: ["ALT"], path: [.init(x: 1, y: 2), .init(x: 3, y: 4), .init(x: 5, y: 6)])
        ]
        XCTAssertEqual(ActionDispatchSummary.batch(actions),
                       "move (20, 30) → double_click left (40, 50) + SHIFT → scroll Δ(-10, 600) at (100, 200) → drag 3 points (1, 2) to (5, 6) + ALT")
    }

    func testNativeSummaryUsesOperationRoleAndGeneratedIDOnly() {
        let element = AccessibilityElement(id: "e218", role: "AXStaticText", label: "private label",
                                           value: "private value", help: "private help")
        XCTAssertEqual(ActionDispatchSummary.native(action: "AXShowMenu", element: element),
                       "AXShowMenu e218 AXStaticText")
        let malformed = AccessibilityElement(id: "private target", role: "private role", label: "private label")
        XCTAssertEqual(ActionDispatchSummary.native(action: "private action", element: malformed),
                       "unsupported AX action <target> AXControl")
    }
}
