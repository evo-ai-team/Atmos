import XCTest
@testable import ChosenCore

final class SpeechTranscriptStateTests: XCTestCase {
    func testVolatileRevisionReplacesWordsInsteadOfDuplicatingThem() {
        var state = SpeechTranscriptState()
        state.replace(start: 0, end: 1, with: [.init(start: 0, end: 1, text: "Hey Chosen")], at: 1)
        state.replace(start: 0, end: 1.5, with: [.init(start: 0, end: 1.5, text: "Hey Mouse open Chrome")], at: 1.5)
        XCTAssertEqual(state.text, "Hey Mouse open Chrome")
    }

    func testEndpointWaitsForBothAudioSilenceAndTranscriptStability() {
        var state = seededState()
        XCTAssertNil(state.beginFinalization(at: 1.9))
        state.observeAudio(end: 3, lastSpeechAt: 2.4)
        XCTAssertNil(state.beginFinalization(at: 3.2))
        XCTAssertNotNil(state.beginFinalization(at: 3.5))
    }

    func testContinuedSpeechInvalidatesInFlightFinalization() {
        var state = seededState()
        let candidate = state.beginFinalization(at: 2.5)!
        XCTAssertTrue(state.observeAudio(end: 3, lastSpeechAt: 2.7))
        XCTAssertFalse(state.isCurrent(candidate))
        XCTAssertFalse(state.commit(candidate))
        XCTAssertEqual(state.text, "open Chrome")
        XCTAssertNil(state.beginFinalization(at: 3.2))
        XCTAssertNotNil(state.beginFinalization(at: 3.8))
    }

    func testLateCorrectionInvalidatesOldSnapshotBeforeSubmission() {
        var state = seededState()
        let candidate = state.beginFinalization(at: 2.5)!
        XCTAssertTrue(state.replace(start: 0.5, end: 1.5, with: [.init(start: 0.5, end: 1.5, text: "open Safari")], at: 2.6))
        XCTAssertFalse(state.commit(candidate))
        XCTAssertEqual(state.text, "open Safari")
        XCTAssertNil(state.beginFinalization(at: 3.2))
        XCTAssertNotNil(state.beginFinalization(at: 3.7))
    }

    func testMoreSilentAudioDoesNotInvalidateSnapshot() {
        var state = seededState()
        let candidate = state.beginFinalization(at: 2.5)!
        XCTAssertFalse(state.observeAudio(end: 4, lastSpeechAt: 1))
        XCTAssertTrue(state.isCurrent(candidate))
        XCTAssertTrue(state.commit(candidate))
        XCTAssertEqual(state.consumedThrough, candidate.through)
        XCTAssertEqual(state.text, "")
        XCTAssertFalse(state.commit(candidate))
    }

    func testQuietMicrophoneCannotFinalizeWhileConvertedAudioStillLags() {
        var state = seededState()
        state.observeAudio(end: 2.5, lastSpeechAt: 1, convertedCaptureAt: 1.2)
        XCTAssertNil(state.beginFinalization(at: 3, latestCaptureAt: 2.98))
        state.observeAudio(end: 4, lastSpeechAt: 1, convertedCaptureAt: 2.94)
        XCTAssertNotNil(state.beginFinalization(at: 3, latestCaptureAt: 2.98))
    }

    func testConversionBacklogAtCommitInvalidatesAndCanRetryWithoutLosingText() {
        var state = seededState()
        state.observeAudio(end: 2.5, lastSpeechAt: 1, convertedCaptureAt: 2.45)
        let candidate = state.beginFinalization(at: 2.5, latestCaptureAt: 2.49)!
        XCTAssertFalse(state.audioIsCaughtUp(at: 3.5, latestCaptureAt: 3.49))
        state.invalidateFinalization()
        XCTAssertFalse(state.commit(candidate))
        XCTAssertEqual(state.text, "open Chrome")
        state.observeAudio(end: 4, lastSpeechAt: 1, convertedCaptureAt: 3.45)
        XCTAssertNotNil(state.beginFinalization(at: 3.5, latestCaptureAt: 3.49))
    }

    func testMissingConvertedCaptureWatermarkCannotStartFinalPass() {
        var state = seededState()
        XCTAssertNil(state.beginFinalization(at: 2.5, latestCaptureAt: 2.49))
    }

    func testCommittedAudioCannotReplayAndTimedNewWordsSurviveOverlappingResult() {
        var state = seededState()
        let candidate = state.beginFinalization(at: 2.5)!
        XCTAssertTrue(state.commit(candidate))
        XCTAssertFalse(state.replace(start: 0.5, end: 1.5, with: [.init(start: 0.5, end: 1.5, text: "open Chrome")], at: 3))
        XCTAssertEqual(state.text, "")
        state.replace(start: 0.5, end: 4, with: [
            .init(start: 0.5, end: 1.5, text: "open Chrome"),
            .init(start: 3, end: 4, text: "scroll down")
        ], at: 4)
        XCTAssertEqual(state.text, "scroll down")
    }

    func testLifecycleDiscardPreventsStaleFinalPassCommit() {
        var state = seededState()
        let candidate = state.beginFinalization(at: 2.5)!
        state.discard(through: 3)
        XCTAssertFalse(state.commit(candidate))
        XCTAssertEqual(state.text, "")
        XCTAssertNil(state.candidate)
    }

    func testEmptyAndDuplicateResultsDoNotCreateExtraUtterances() {
        var state = SpeechTranscriptState()
        state.observeAudio(end: 5, lastSpeechAt: 0)
        XCTAssertNil(state.beginFinalization(at: 5))
        state.replace(start: 1, end: 2, with: [.init(start: 1, end: 2, text: "hello")], at: 2)
        let candidate = state.beginFinalization(at: 5)!
        XCTAssertFalse(state.replace(start: 1, end: 2, with: [.init(start: 1, end: 2, text: "hello")], at: 5.1))
        XCTAssertTrue(state.isCurrent(candidate))
    }

    private func seededState() -> SpeechTranscriptState {
        var state = SpeechTranscriptState()
        state.replace(start: 0.5, end: 1.5, with: [.init(start: 0.5, end: 1.5, text: "open Chrome")], at: 1.2)
        state.observeAudio(end: 2.5, lastSpeechAt: 1)
        return state
    }
}
