import XCTest
@testable import AtmosCore

final class WakeAudioWindowTests: XCTestCase {
    func testLongUtteranceCanReviseItsWakeDuringFinalReplay() {
        XCTAssertFalse(WakeAudioWindow.emptyConfirmationExpired(audioDuration: 10, hasWords: true,
            heardWake: false, silence: 0.6))
        XCTAssertFalse(WakeAudioWindow.emptyConfirmationExpired(audioDuration: 10, hasWords: false,
            heardWake: false, silence: 0.1))
        XCTAssertTrue(WakeAudioWindow.emptyConfirmationExpired(audioDuration: 10, hasWords: false,
            heardWake: false, silence: 0.6))
    }

    func testExpiredStartAfterLongStandbyKeepsWakeOnsetAndRequiresCleanWake() throws {
        var window = WakeAudioWindow()
        window.observe("Hey", at: 12.6)
        window.observe("Hey Atmos don't open Notes", at: 14.1)
        let selected = try XCTUnwrap(window.select(attributedStart: 0, earliest: 6.2,
            latest: 14.1, recentOnset: 12.2))
        XCTAssertEqual(selected.start, 11.6, accuracy: 0.000_001)
        XCTAssertTrue(selected.verifyWake)
        XCTAssertFalse(WakeAudioWindow.containsWake("open Notes"))
        XCTAssertTrue(WakeAudioWindow.containsWake("Hey Atmos, don't open Notes"))
    }

    func testQuietWakeWithoutAThresholdCrossingUsesBoundedContext() throws {
        var window = WakeAudioWindow()
        window.observe("Hey Atmos open Notes", at: 100)
        let selected = try XCTUnwrap(window.select(attributedStart: nil, earliest: 92,
            latest: 100, recentOnset: nil))
        XCTAssertEqual(selected.start, 98)
        XCTAssertTrue(selected.verifyWake)
    }

    func testRecentAttributedWordRangePreservesQuietPrefix() throws {
        var window = WakeAudioWindow()
        window.observe("Hey", at: 12.6)
        let selected = try XCTUnwrap(window.select(attributedStart: 12, earliest: 6.2,
            latest: 14.1, recentOnset: 13.5))
        XCTAssertEqual(selected.start, 12)
        XCTAssertFalse(selected.verifyWake)
    }

    func testGenuinelyMissingWakeDoesNotStartFromASuffix() {
        var window = WakeAudioWindow()
        window.observe("Hey", at: 12.6)
        XCTAssertNil(window.select(attributedStart: 12, earliest: 20,
            latest: 28, recentOnset: 26.8))
    }
}
