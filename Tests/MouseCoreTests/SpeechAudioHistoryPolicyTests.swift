import XCTest
@testable import MouseCore

final class SpeechAudioHistoryPolicyTests: XCTestCase {
    func testRawSpeechBlocksDispatchBeforeTheActivityTimerRuns() {
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
        // Audio arriving after the commit must gate the next action immediately.
        XCTAssertTrue(gate.hasUnconsumedSpeech(lastSpeechAt: 13.1))
    }

    func testLongSilenceCanBeTrimmedWithoutDependingOnCoarseTranscriptTimestamp() {
        XCTAssertEqual(SpeechAudioHistoryPolicy.keepFrom(consumedThrough: 0, audioEnd: 30,
            firstUnconsumedSpeechStart: nil, hasUnfinishedText: false), 22)
        // An ASR range can begin at time zero although the actual speech only
        // begins at 29. Its retained audio must still be available for replay.
        XCTAssertEqual(SpeechAudioHistoryPolicy.keepFrom(consumedThrough: 0, audioEnd: 30,
            firstUnconsumedSpeechStart: 29, hasUnfinishedText: false), 22)
    }

    func testDelayedFirstResultCannotTrimDetectedCommandSpeech() {
        XCTAssertEqual(SpeechAudioHistoryPolicy.keepFrom(consumedThrough: 0, audioEnd: 30,
            firstUnconsumedSpeechStart: 11, hasUnfinishedText: false), 10.4, accuracy: 0.001)
    }

    func testRetainsFullPendingUtteranceAndLeadingContext() {
        XCTAssertEqual(SpeechAudioHistoryPolicy.keepFrom(consumedThrough: 5, audioEnd: 30,
            firstUnconsumedSpeechStart: 12, hasUnfinishedText: true), 4.4, accuracy: 0.001)
    }

    func testConsumedSpeechDoesNotPinHistory() {
        XCTAssertEqual(SpeechAudioHistoryPolicy.keepFrom(consumedThrough: 15, audioEnd: 30,
            firstUnconsumedSpeechStart: nil, hasUnfinishedText: false), 22)
    }

    func testCoarseRangeOverTrimmedSilenceCanCommitFullReplay() {
        XCTAssertTrue(SpeechAudioHistoryPolicy.replayHasCompleteCoverage(firstTextStart: 0, retainedAudioStart: 22,
            provisionalText: "Hey Mouse open Chrome", finalText: "Hey Mouse, open Chrome."))
    }

    func testQuietMissingFirstWordsCannotBecomeAnActionAfterHistoryTrim() {
        XCTAssertFalse(SpeechAudioHistoryPolicy.replayHasCompleteCoverage(firstTextStart: 0, retainedAudioStart: 22,
            provisionalText: "Do not delete the file", finalText: "Delete the file"))
        // A correction is also uncertain when the necessary audio is missing.
        XCTAssertFalse(SpeechAudioHistoryPolicy.replayHasCompleteCoverage(firstTextStart: 0, retainedAudioStart: 22,
            provisionalText: "open Crome", finalText: "open Chrome"))
    }

    func testFullAudioCoverageAllowsAccurateSecondPassCorrections() {
        XCTAssertTrue(SpeechAudioHistoryPolicy.replayHasCompleteCoverage(firstTextStart: 24, retainedAudioStart: 22,
            provisionalText: "open Crome", finalText: "open Chrome"))
    }
}
