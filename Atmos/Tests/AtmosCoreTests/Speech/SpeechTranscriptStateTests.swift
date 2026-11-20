import XCTest
@testable import AtmosCore

final class SpeechTranscriptStateTests: XCTestCase {
    func testVolatileRevisionReplacesWordsInsteadOfDuplicatingThem() {
        var state = SpeechTranscriptState()
        state.replace(start: 0, end: 1, with: [.init(start: 0, end: 1, text: "Hey Atmos")], at: 1)
        state.replace(start: 0, end: 1.5, with: [.init(start: 0, end: 1.5, text: "Hey Atmos open Chrome")], at: 1.5)
        XCTAssertEqual(state.text, "Hey Atmos open Chrome")
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

    func testFiveHundredMillisecondWindowWaitsForSpeechAndRevisionsAndRejectsStalePasses() throws {
        var state = seededState()
        XCTAssertEqual(SpeechAudioHistoryPolicy.endpointSilence, 0.500)
        XCTAssertNil(state.beginFinalization(at: 1.699, silenceDuration: SpeechAudioHistoryPolicy.endpointSilence))
        let first = try XCTUnwrap(state.beginFinalization(at: 1.701, silenceDuration: SpeechAudioHistoryPolicy.endpointSilence))

        XCTAssertTrue(state.observeAudio(end: 2.6, lastSpeechAt: 1.71))
        XCTAssertFalse(state.commit(first))
        XCTAssertNil(state.beginFinalization(at: 2.209, silenceDuration: SpeechAudioHistoryPolicy.endpointSilence))
        let second = try XCTUnwrap(state.beginFinalization(at: 2.211, silenceDuration: SpeechAudioHistoryPolicy.endpointSilence))

        XCTAssertTrue(state.replace(start: 0.5, end: 1.5, with: [.init(start: 0.5, end: 1.5, text: "open Safari")], at: 2.22))
        XCTAssertFalse(state.commit(second))
        XCTAssertEqual(state.text, "open Safari")
        XCTAssertNil(state.beginFinalization(at: 2.719, silenceDuration: SpeechAudioHistoryPolicy.endpointSilence))
        let corrected = try XCTUnwrap(state.beginFinalization(at: 2.721, silenceDuration: SpeechAudioHistoryPolicy.endpointSilence))
        XCTAssertTrue(state.commit(corrected))
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

    func testFastTranscriptCommitsCurrentWordsOnceAndAdvancesAudioBoundary() throws {
        var state = seededState()
        state.observeAudio(end: 2.5, lastSpeechAt: 1, convertedCaptureAt: 2.45)
        let candidate = try XCTUnwrap(state.beginFinalization(at: 2.5, latestCaptureAt: 2.49))
        XCTAssertEqual(state.commitLiveTranscript(candidate, at: 2.5, lastSpeechAt: 1, latestCaptureAt: 2.49), "open Chrome")
        XCTAssertEqual(state.consumedThrough, 2.5)
        XCTAssertEqual(state.text, "")
        XCTAssertNil(state.commitLiveTranscript(candidate, at: 2.5, lastSpeechAt: 1, latestCaptureAt: 2.49))
        // Late live results for committed audio cannot submit the command twice.
        state.replace(start: 0.5, end: 1.5, with: [.init(start: 0.5, end: 1.5, text: "open Chrome")], at: 2.6)
        XCTAssertEqual(state.text, "")
    }

    func testFastTranscriptRejectsSpeechCapturedAfterEndpoint() throws {
        var state = seededState()
        state.observeAudio(end: 2.5, lastSpeechAt: 1, convertedCaptureAt: 2.45)
        let candidate = try XCTUnwrap(state.beginFinalization(at: 2.5, latestCaptureAt: 2.49))
        XCTAssertNil(state.commitLiveTranscript(candidate, at: 2.55, lastSpeechAt: 2.51, latestCaptureAt: 2.54))
        XCTAssertEqual(state.text, "open Chrome")
        XCTAssertEqual(state.consumedThrough, 0)
        XCTAssertNil(state.candidate)
    }

    func testFastTranscriptRejectsRevisedOrResetCandidate() throws {
        var state = seededState()
        state.observeAudio(end: 2.5, lastSpeechAt: 1, convertedCaptureAt: 2.45)
        let candidate = try XCTUnwrap(state.beginFinalization(at: 2.5, latestCaptureAt: 2.49))
        state.replace(start: 0.5, end: 1.5, with: [.init(start: 0.5, end: 1.5, text: "do not open Chrome")], at: 2.51)
        XCTAssertNil(state.commitLiveTranscript(candidate, at: 2.52, lastSpeechAt: 1, latestCaptureAt: 2.51))
        XCTAssertEqual(state.text, "do not open Chrome")
        state.discard(through: 2.5)
        XCTAssertNil(state.commitLiveTranscript(candidate, at: 2.52, lastSpeechAt: 1, latestCaptureAt: 2.51))
    }

    func testFastTranscriptWaitsForPendingAudioWithoutLosingWords() throws {
        var state = seededState()
        state.observeAudio(end: 2.5, lastSpeechAt: 1, convertedCaptureAt: 2.45)
        let candidate = try XCTUnwrap(state.beginFinalization(at: 2.5, latestCaptureAt: 2.49))
        XCTAssertNil(state.commitLiveTranscript(candidate, at: 2.8, lastSpeechAt: 1, latestCaptureAt: 2.79))
        XCTAssertEqual(state.text, "open Chrome")
        state.invalidateFinalization()
        state.observeAudio(end: 2.9, lastSpeechAt: 1, convertedCaptureAt: 2.85)
        let retry = try XCTUnwrap(state.beginFinalization(at: 2.9, latestCaptureAt: 2.89))
        XCTAssertEqual(state.commitLiveTranscript(retry, at: 2.9, lastSpeechAt: 1, latestCaptureAt: 2.89), "open Chrome")
    }

    private func seededState() -> SpeechTranscriptState {
        var state = SpeechTranscriptState()
        state.replace(start: 0.5, end: 1.5, with: [.init(start: 0.5, end: 1.5, text: "open Chrome")], at: 1.2)
        state.observeAudio(end: 2.5, lastSpeechAt: 1)
        return state
    }
}
