import XCTest
@testable import AtmosCore

final class SpeechRecoveryStateTests: XCTestCase {
    func testRecoveryIsBoundedAndBacksOff() throws {
        var state = SpeechRecoveryState()
        XCTAssertNil(state.nextAttempt(at: 0))
        state.enable()
        XCTAssertEqual(try XCTUnwrap(state.nextAttempt(at: 0)).delay, 0.3)
        XCTAssertEqual(try XCTUnwrap(state.nextAttempt(at: 1)).delay, 0.8)
        XCTAssertEqual(try XCTUnwrap(state.nextAttempt(at: 2)).delay, 1.5)
        XCTAssertNil(state.nextAttempt(at: 3))
        XCTAssertNotNil(state.nextAttempt(at: 60))
    }

    func testExplicitPauseInvalidatesPendingRecoveryAndReenableCannotResurrectIt() throws {
        var state = SpeechRecoveryState()
        state.enable()
        let old = try XCTUnwrap(state.nextAttempt(at: 0))
        XCTAssertTrue(state.isCurrent(old))
        state.disable()
        XCTAssertFalse(state.isCurrent(old))
        XCTAssertNil(state.nextAttempt(at: 1))
        state.enable()
        XCTAssertFalse(state.isCurrent(old))
        XCTAssertTrue(state.isCurrent(try XCTUnwrap(state.nextAttempt(at: 2))))
    }
}
