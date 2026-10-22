import XCTest
@testable import MouseCore

final class ActionProgressGuardTests: XCTestCase {
    private let click = ComputerAction(type: "click", x: 100, y: 120, button: "left")

    func testThreeIdenticalDispatchesOnAnUnchangedScreenPause() {
        var guardState = ActionProgressGuard()
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNotNil(record(&guardState, actions: [click]))
        guardState.reset()
        XCTAssertNil(record(&guardState, actions: [click]))
    }

    func testAdvancingTaskHasNoStepLimit() {
        var guardState = ActionProgressGuard()
        for step in 0..<40 {
            XCTAssertNil(record(&guardState, actions: [click], before: frame(UInt8(step)), after: frame(UInt8(step + 1))))
        }
        XCTAssertNil(record(&guardState, actions: [click], before: frame(40), after: frame(40)))
        XCTAssertNil(record(&guardState, actions: [click], before: frame(40), after: frame(40)))
    }

    func testWaitsIncludingMixedBatchesBreakStalledStreak() {
        var guardState = ActionProgressGuard()
        for actions in [[ComputerAction(type: "wait")], [click, ComputerAction(type: "wait")]] {
            XCTAssertNil(record(&guardState, actions: [click]))
            XCTAssertNil(record(&guardState, actions: [click]))
            for _ in 0..<20 { XCTAssertNil(record(&guardState, actions: actions)) }
        }
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNotNil(record(&guardState, actions: [click]))
    }

    func testObservationOnlyLoopsHaveDistinctReasonAndDoNotShareInputStreak() {
        var guardState = ActionProgressGuard()
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNil(record(&guardState, actions: [click]))
        let screenshot = [ComputerAction(type: "screenshot")]
        XCTAssertNil(record(&guardState, actions: screenshot))
        XCTAssertNil(record(&guardState, actions: screenshot))
        XCTAssertTrue(record(&guardState, actions: screenshot)?.contains("without sending input") == true)
        XCTAssertNil(record(&guardState, actions: []))
        XCTAssertNil(record(&guardState, actions: screenshot))
    }

    func testEntireGeneratedBatchDeterminesIdentity() {
        let first = [click, ComputerAction(type: "type", text: "first")]
        let second = [click, ComputerAction(type: "type", text: "second")]
        var guardState = ActionProgressGuard()
        XCTAssertNil(record(&guardState, actions: first))
        XCTAssertNil(record(&guardState, actions: first))
        XCTAssertNil(record(&guardState, actions: second))
        XCTAssertNil(record(&guardState, actions: second))
        XCTAssertNotNil(record(&guardState, actions: second))
        XCTAssertNil(record(&guardState, actions: Array(second.reversed())))
    }

    func testChangedScreenshotWithinOrBetweenBatchesBreaksStreak() {
        var guardState = ActionProgressGuard()
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNil(record(&guardState, actions: [click], before: frame(1), after: frame(2)))
        XCTAssertNil(record(&guardState, actions: [click], before: frame(2), after: frame(2)))
        XCTAssertNil(record(&guardState, actions: [click], before: frame(2), after: frame(2)))
        // A change before the next batch also breaks continuity, even if that
        // batch's own before/after images happen to match one another.
        XCTAssertNil(record(&guardState, actions: [click], before: frame(3), after: frame(3)))
        XCTAssertNil(record(&guardState, actions: [click], before: frame(3), after: frame(3)))
        XCTAssertNotNil(record(&guardState, actions: [click], before: frame(3), after: frame(3)))
    }

    func testApplicationAndEveryDisplayGeometryChangeBreakContinuity() {
        var variants: [ScreenshotFrame] = []
        var changed = frame(); changed.displayID += 1; variants.append(changed)
        changed = frame(); changed.width += 1; variants.append(changed)
        changed = frame(); changed.height += 1; variants.append(changed)
        changed = frame(); changed.originX += 1; variants.append(changed)
        changed = frame(); changed.originY += 1; variants.append(changed)
        changed = frame(); changed.pointWidth += 1; variants.append(changed)
        changed = frame(); changed.pointHeight += 1; variants.append(changed)
        for newFrame in variants {
            var guardState = ActionProgressGuard()
            XCTAssertNil(record(&guardState, actions: [click]))
            XCTAssertNil(record(&guardState, actions: [click]))
            XCTAssertNil(record(&guardState, actions: [click], before: newFrame, after: newFrame))
            XCTAssertNil(record(&guardState, actions: [click], before: newFrame, after: newFrame))
            XCTAssertNotNil(record(&guardState, actions: [click], before: newFrame, after: newFrame))
        }
        var guardState = ActionProgressGuard()
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNil(record(&guardState, actions: [click]))
        XCTAssertNil(record(&guardState, actions: [click], beforePID: 42, afterPID: 99))
        XCTAssertNil(record(&guardState, actions: [click], beforePID: 99, afterPID: 99))
        XCTAssertNil(record(&guardState, actions: [click], beforePID: 99, afterPID: 99))
        // Switching processes between batches is not a continuation either.
        XCTAssertNil(record(&guardState, actions: [click], beforePID: 42, afterPID: 42))
    }

    func testNativeSnapshotIDsChangeWithoutBreakingStableTargetStreak() {
        var guardState = ActionProgressGuard()
        for id in ["e1", "e79"] {
            XCTAssertNil(recordNative(&guardState, element: target(id: id)))
        }
        XCTAssertNotNil(recordNative(&guardState, element: target(id: "e243")))
    }

    func testFineGrainedNativeAdjustmentsAreNotJudgedByPixelsAlone() {
        var guardState = ActionProgressGuard()
        for action in ["AXIncrement", "AXDecrement"] {
            XCTAssertNil(recordNative(&guardState, element: target()))
            XCTAssertNil(recordNative(&guardState, element: target()))
            for _ in 0..<40 {
                XCTAssertNil(recordNative(&guardState, element: target(), action: action))
            }
        }
        // An adjustment also clears a preceding press streak.
        XCTAssertNil(recordNative(&guardState, element: target()))
        XCTAssertNil(recordNative(&guardState, element: target()))
        XCTAssertNotNil(recordNative(&guardState, element: target()))
    }

    func testDifferentNativeTargetOrActionStartsANewStreak() {
        let original = target()
        var variants: [AccessibilityElement] = []
        var changed = original; changed.role = "AXLink"; variants.append(changed)
        changed = original; changed.subrole = "AXCloseButton"; variants.append(changed)
        changed = original; changed.label = "Other button"; variants.append(changed)
        changed = original; changed.screenBounds?.x += 1; variants.append(changed)
        for newTarget in variants {
            var guardState = ActionProgressGuard()
            XCTAssertNil(recordNative(&guardState, element: original))
            XCTAssertNil(recordNative(&guardState, element: original))
            XCTAssertNil(recordNative(&guardState, element: newTarget))
            XCTAssertNil(recordNative(&guardState, element: newTarget))
            XCTAssertNotNil(recordNative(&guardState, element: newTarget))
        }
        var guardState = ActionProgressGuard()
        XCTAssertNil(recordNative(&guardState, element: original))
        XCTAssertNil(recordNative(&guardState, element: original))
        XCTAssertNil(recordNative(&guardState, element: original, action: "AXShowMenu"))
    }

    func testMissingOrInvalidCaptureDoesNotCountAsNoProgress() {
        var guardState = ActionProgressGuard()
        var invalid = frame(); invalid.data = Data()
        for _ in 0..<4 { XCTAssertNil(record(&guardState, actions: [click], before: invalid, after: invalid)) }
        invalid = frame(); invalid.pointWidth = 0
        for _ in 0..<4 { XCTAssertNil(record(&guardState, actions: [click], before: invalid, after: invalid)) }
        for _ in 0..<4 { XCTAssertNil(record(&guardState, actions: [click], beforePID: 0, afterPID: 0)) }
    }

    private func frame(_ byte: UInt8 = 1) -> ScreenshotFrame {
        ScreenshotFrame(data: Data([byte]), width: 1200, height: 800,
                        pointWidth: 1200, pointHeight: 800, displayID: 1)
    }

    private func target(id: String = "e1") -> AccessibilityElement {
        AccessibilityElement(id: id, role: "AXButton", label: "Continue", enabled: true,
                             actions: ["AXPress"], screenBounds: AccessibilityBounds(x: 100, y: 120, width: 50, height: 20))
    }

    private func record(_ guardState: inout ActionProgressGuard, actions: [ComputerAction],
                        before: ScreenshotFrame? = nil, after: ScreenshotFrame? = nil,
                        beforePID: Int32 = 42, afterPID: Int32 = 42) -> String? {
        guardState.recordGenerated(actions, before: before ?? frame(), after: after ?? frame(),
                                   processIDBefore: beforePID, processIDAfter: afterPID)
    }

    private func recordNative(_ guardState: inout ActionProgressGuard, element: AccessibilityElement,
                              action: String = "AXPress") -> String? {
        guardState.recordNative(action: action, element: element, before: frame(), after: frame(),
                                processIDBefore: 42, processIDAfter: 42)
    }
}
