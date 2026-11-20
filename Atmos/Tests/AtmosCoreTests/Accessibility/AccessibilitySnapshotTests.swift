import XCTest
@testable import AtmosCore

final class AccessibilitySnapshotTests: XCTestCase {
    func testBoundsUseActualPixelScalesAndQuartzOrigins() throws {
        let frame = ScreenshotFrame(data: Data(), width: 1600, height: 1038,
                                    originX: -3456, originY: -2242, pointWidth: 3456, pointHeight: 2242)
        let box = AccessibilityBounds(x: -2592, y: -1681.5, width: 864, height: 560.5)
        let mapped = try XCTUnwrap(box.screenshotBounds(in: frame))
        XCTAssertEqual(mapped.x, 400, accuracy: 0.000_001)
        XCTAssertEqual(mapped.y, 259.5, accuracy: 0.000_001)
        XCTAssertEqual(mapped.width, 400, accuracy: 0.000_001)
        XCTAssertEqual(mapped.height, 259.5, accuracy: 0.000_001)
        XCTAssertEqual(try frame.screenPoint(x: mapped.x, y: mapped.y), ActionPoint(x: box.x, y: box.y))
    }

    func testPartiallyVisibleBoundsClipWithoutMovingTheirVisibleEdge() throws {
        let frame = ScreenshotFrame(data: Data(), width: 1000, height: 500, pointWidth: 2000, pointHeight: 1000)
        let box = AccessibilityBounds(x: -100, y: 900, width: 300, height: 300)
        XCTAssertEqual(box.screenshotBounds(in: frame), AccessibilityBounds(x: 0, y: 450, width: 100, height: 50))
        XCTAssertNil(AccessibilityBounds(x: 2000, y: 0, width: 100, height: 100).screenshotBounds(in: frame))
        XCTAssertNil(AccessibilityBounds(x: 0, y: 1000, width: 100, height: 100).screenshotBounds(in: frame))
    }

    func testInvalidGeometryNeverProducesAUsableTargetRectangle() {
        let frame = ScreenshotFrame(data: Data(), width: 1000, height: 500, pointWidth: 2000, pointHeight: 1000)
        for box in [AccessibilityBounds(x: .nan, y: 0, width: 10, height: 10),
                    AccessibilityBounds(x: 0, y: 0, width: -.infinity, height: 10),
                    AccessibilityBounds(x: 0, y: 0, width: 10, height: 0),
                    AccessibilityBounds(x: .greatestFiniteMagnitude, y: 0, width: .greatestFiniteMagnitude, height: 10)] {
            XCTAssertNil(box.screenshotBounds(in: frame))
        }
        var invalid = frame
        invalid.pointWidth = 0
        XCTAssertNil(AccessibilityBounds(x: 0, y: 0, width: 10, height: 10).screenshotBounds(in: invalid))
    }

    func testSecureFieldContentCannotLeakThroughSnapshotInitializer() throws {
        let element = AccessibilityElement(id: "e1", role: "AXTextField", subrole: "AXSecureTextField",
                                           label: "private title", value: "private value", help: "private help",
                                           enabled: true, actions: ["AXPress"], secure: true)
        let snapshot = AccessibilitySnapshot(processID: 42, elements: [element], rootIDs: ["e1"])
        let json = snapshot.contextText
        XCTAssertFalse(json.contains("private"))
        let restored = try JSONDecoder().decode(AccessibilitySnapshot.self, from: Data(json.utf8))
        XCTAssertTrue(restored.elements[0].secure)
        XCTAssertNil(restored.elements[0].value)
        XCTAssertEqual(restored.elements[0].actions, [])
        XCTAssertEqual(restored.elements[0].label, "Secure text field")
    }

    func testSerializedTreePreservesReadOnlyTextHierarchyAndPartialStatus() throws {
        let root = AccessibilityElement(id: "e1", childIDs: ["e2"], role: "AXWindow", label: "Browser",
                                        childCount: 3, childrenTruncated: true)
        let text = AccessibilityElement(id: "e2", parentID: "e1", role: "AXStaticText", value: "Article headline")
        let source = AccessibilitySnapshot(processID: 42, elements: [root, text], truncated: true,
                                           rootIDs: ["e1"], truncationReasons: ["time_limit"])
        let restored = try JSONDecoder().decode(AccessibilitySnapshot.self, from: Data(source.contextText.utf8))
        XCTAssertEqual(restored.id, source.id)
        XCTAssertEqual(restored.elements, source.elements)
        XCTAssertEqual(restored.truncationReasons, ["time_limit"])
        XCTAssertTrue(restored.truncated)
        XCTAssertNil(restored.elements[1].enabled)
        XCTAssertTrue(restored.elements[1].actions.isEmpty)
    }

    func testUnavailableTreeRemainsDistinctFromCompleteEmptyTree() throws {
        let source = AccessibilitySnapshot(processID: 42, elements: [], unavailableReason: "Application did not respond")
        let restored = try JSONDecoder().decode(AccessibilitySnapshot.self, from: Data(source.contextText.utf8))
        XCTAssertEqual(restored.unavailableReason, "Application did not respond")
        XCTAssertEqual(restored.elements.count, 0)
    }
}
