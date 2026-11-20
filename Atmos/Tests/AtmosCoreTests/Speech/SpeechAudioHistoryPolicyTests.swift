import XCTest
@testable import AtmosCore

final class SpeechAudioHistoryPolicyTests: XCTestCase {
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
            provisionalText: "Hey Atmos open Chrome", finalText: "Hey Atmos, open Chrome."))
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
