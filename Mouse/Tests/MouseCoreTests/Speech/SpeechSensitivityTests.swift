import XCTest
@testable import MouseCore

final class SpeechSensitivityTests: XCTestCase {
    func testMidpointPreservesExistingActivityThreshold() {
        XCTAssertEqual(SpeechSensitivity.defaultValue, 0.5)
        XCTAssertEqual(SpeechSensitivity.energyThreshold(for: 0.5), 0.006)
    }

    func testHigherSensitivityDetectsQuieterSoundWithoutOpeningTheGateCompletely() throws {
        let thresholds = stride(from: 0.0, through: 1.0, by: 0.1)
            .map(SpeechSensitivity.energyThreshold(for:))
        XCTAssertTrue(zip(thresholds, thresholds.dropFirst()).allSatisfy { $0 > $1 })
        XCTAssertEqual(try XCTUnwrap(thresholds.first), 0.024, accuracy: 0.000001)
        XCTAssertEqual(try XCTUnwrap(thresholds.last), 0.0015, accuracy: 0.000001)
    }

    func testInvalidPersistedValuesCannotCreateAnInvalidActivityGate() {
        XCTAssertEqual(SpeechSensitivity.normalized(-1), 0)
        XCTAssertEqual(SpeechSensitivity.normalized(2), 1)
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(SpeechSensitivity.normalized(value), 0.5)
            XCTAssertEqual(SpeechSensitivity.energyThreshold(for: value), 0.006)
        }
    }
}
