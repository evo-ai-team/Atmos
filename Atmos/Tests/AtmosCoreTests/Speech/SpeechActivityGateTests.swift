import XCTest
@testable import AtmosCore

final class SpeechActivityGateTests: XCTestCase {
    func testRawSpeechIsVisibleBeforeTheActivityTimerRuns() {
        var gate = SpeechActivityGate(lastSpeechAt: 10)
        XCTAssertFalse(gate.hasUnconsumedSpeech(lastSpeechAt: 10))
        XCTAssertTrue(gate.hasUnconsumedSpeech(lastSpeechAt: 11))
        XCTAssertTrue(gate.observe(lastSpeechAt: 11))
        XCTAssertFalse(gate.observe(lastSpeechAt: 11))
        XCTAssertTrue(gate.observe(lastSpeechAt: 11.1))
    }

    func testTextFreeActivityReleasesOnceAfterFiveHundredMilliseconds() {
        var gate = SpeechActivityGate(lastSpeechAt: 10)
        XCTAssertTrue(gate.observe(lastSpeechAt: 11))
        XCTAssertFalse(gate.finishIdle(at: 11.499, lastSpeechAt: 11, lastResultAt: 10,
                                       hasUnfinishedText: false, isFinalizing: false))
        XCTAssertTrue(gate.hasUnconsumedSpeech(lastSpeechAt: 11))
        XCTAssertTrue(gate.finishIdle(at: 11.5, lastSpeechAt: 11, lastResultAt: 10,
                                      hasUnfinishedText: false, isFinalizing: false))
        XCTAssertFalse(gate.hasUnconsumedSpeech(lastSpeechAt: 11))
        XCTAssertFalse(gate.finishIdle(at: 12, lastSpeechAt: 11, lastResultAt: 10,
                                       hasUnfinishedText: false, isFinalizing: false))
    }

    func testUnfinishedWordsOrReplayCannotReleaseSpeechGateOnSilence() {
        var gate = SpeechActivityGate(lastSpeechAt: 10)
        _ = gate.observe(lastSpeechAt: 11)
        XCTAssertFalse(gate.finishIdle(at: 12, lastSpeechAt: 11, lastResultAt: 11,
                                       hasUnfinishedText: true, isFinalizing: false))
        XCTAssertFalse(gate.finishIdle(at: 12, lastSpeechAt: 11, lastResultAt: 11,
                                       hasUnfinishedText: false, isFinalizing: true))
        XCTAssertFalse(gate.finishIdle(at: 12, lastSpeechAt: 11, lastResultAt: 11.6,
                                       hasUnfinishedText: false, isFinalizing: false))
        XCTAssertTrue(gate.hasUnconsumedSpeech(lastSpeechAt: 11))
        gate.consume(lastSpeechAt: 11)
        XCTAssertFalse(gate.hasUnconsumedSpeech(lastSpeechAt: 11))
        XCTAssertFalse(gate.finishIdle(at: 13, lastSpeechAt: 11, lastResultAt: 11.6,
                                       hasUnfinishedText: false, isFinalizing: false))
        // Audio arriving after the commit belongs to the next utterance immediately.
        XCTAssertTrue(gate.hasUnconsumedSpeech(lastSpeechAt: 13.1))
    }
}
