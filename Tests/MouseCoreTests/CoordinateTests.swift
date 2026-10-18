import XCTest
@testable import MouseCore

final class CoordinateTests: XCTestCase {
    private func frame(width: Int = 1_600, height: Int = 900, originX: Double = 0, originY: Double = 0,
                       pointWidth: Double = 2_560, pointHeight: Double = 1_440) -> ScreenshotFrame {
        ScreenshotFrame(data: Data(), width: width, height: height, originX: originX, originY: originY,
                        pointWidth: pointWidth, pointHeight: pointHeight, displayID: 1)
    }

    func testDownscaledScreenshotMapsToDisplayPoints() throws {
        let point = try frame().screenPoint(x: 800, y: 450)
        XCTAssertEqual(point, ActionPoint(x: 1_280, y: 720))
    }

    func testSecondaryDisplayLeftAndAboveMainDisplay() throws {
        let shot = frame(originX: -2_560, originY: -1_440)
        XCTAssertEqual(try shot.screenPoint(x: 0, y: 0), ActionPoint(x: -2_560, y: -1_440))
        XCTAssertEqual(try shot.screenPoint(x: 800, y: 450), ActionPoint(x: -1_280, y: -720))
    }

    func testUnequalRoundingUsesEachActualImageDimension() throws {
        let shot = frame(width: 1_600, height: 1_038, originX: 1_512, originY: 82, pointWidth: 3_456, pointHeight: 2_242)
        let point = try shot.screenPoint(x: 800, y: 519)
        XCTAssertEqual(point.x, 3_240, accuracy: 0.000_001)
        XCTAssertEqual(point.y, 1_203, accuracy: 0.000_001)
    }

    func testLastPixelRemainsInsideDisplay() throws {
        let point = try frame().screenPoint(x: 1_599, y: 899)
        XCTAssertLessThan(point.x, 2_560)
        XCTAssertLessThan(point.y, 1_440)
    }

    func testRejectsCoordinatesOutsideImageAndNonfiniteValues() {
        for point in [ActionPoint(x: -1, y: 0), ActionPoint(x: 0, y: -1), ActionPoint(x: 1_600, y: 0),
                      ActionPoint(x: 0, y: 900), ActionPoint(x: .nan, y: 0), ActionPoint(x: 0, y: .infinity)] {
            XCTAssertThrowsError(try frame().screenPoint(x: point.x, y: point.y))
        }
    }

    func testRejectsInvalidFrameGeometry() {
        let invalidFrames = [frame(width: 0), frame(height: -1), frame(pointWidth: 0), frame(pointHeight: -1),
                             frame(originX: .infinity), frame(originY: .nan), frame(pointWidth: .infinity), frame(pointHeight: .nan)]
        for shot in invalidFrames {
            XCTAssertThrowsError(try shot.screenPoint(x: 0, y: 0))
        }
    }
}
