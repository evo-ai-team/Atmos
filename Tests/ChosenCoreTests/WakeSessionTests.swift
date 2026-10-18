import XCTest
@testable import ChosenCore

final class WakeSessionTests: XCTestCase {
    func testStandbyNeverEmitsCommandForOrdinarySpeechOrPhoneticLookalikes() {
        for transcript in ["Open Safari", "they chose an excellent option", "a chosen one", "hey Chosenly open Safari", "hey mousy open Safari", "stop listening", "go to sleep"] {
            var session = WakeSession()
            XCTAssertEqual(session.receive(transcript, at: 0), [], transcript)
            XCTAssertEqual(session.finishUtterance(at: 1), [], transcript)
            XCTAssertFalse(session.isActive, transcript)
        }
    }

    func testMouseWakePhraseWaitsForCommandAndKeepsFullCumulativePartial() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey, Mouse!", at: 0), [.activated])
        XCTAssertEqual(session.finishUtterance(at: 0.8), [])
        XCTAssertEqual(session.receive("Hey, Mouse! Open", at: 1), [.partial("Open")])
        XCTAssertEqual(session.receive("Hey, Mouse! Open Safari", at: 1.3), [.partial("Open Safari")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("Open Safari")])
    }

    func testLegacyChosenWakePhraseStillWorks() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey Chosen open Chrome", at: 0), [.activated, .partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 1), [.command("open Chrome")])
        XCTAssertTrue(session.isActive)
    }

    func testRepeatedPartialsAndFinalResultDoNotResubmit() {
        var session = WakeSession()
        _ = session.receive("Hey Mouse open Safari", at: 0)
        XCTAssertEqual(session.receive("Hey Mouse open Safari", at: 0.2), [])
        XCTAssertEqual(session.finishUtterance(at: 1), [.command("open Safari")])
        XCTAssertEqual(session.receive("Hey Mouse open Safari.", at: 1.2), [])
        XCTAssertEqual(session.finishUtterance(at: 2), [])
        XCTAssertEqual(session.receive("Hey Mouse open Safari now search for cats", at: 3), [.partial("now search for cats")])
        XCTAssertEqual(session.finishUtterance(at: 4), [.command("now search for cats")])
    }

    func testActiveSessionAcceptsFollowUpAfterHoursOfSilence() {
        var session = WakeSession()
        _ = session.receive("Hey Mouse", at: 0)
        session.beginRecognition()
        XCTAssertEqual(session.finishUtterance(at: 86_400), [])
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.receive("open Safari", at: 86_405), [.partial("open Safari")])
        XCTAssertEqual(session.finishUtterance(at: 86_406), [.command("open Safari")])
        XCTAssertTrue(session.isActive)
    }

    func testAllExplicitSleepPhrasesDeactivateAndDiscardPendingCommand() {
        for phrase in ["stop listening", "go to sleep", "sleep Mouse", "please stop listening", "Mouse go to sleep", "sleep Chosen"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(phrase, at: 1), [.deactivated], phrase)
            XCTAssertFalse(session.isActive, phrase)
            XCTAssertEqual(session.finishUtterance(at: 2), [], phrase)
            session.beginRecognition()
            XCTAssertEqual(session.receive("open Notes", at: 3), [], phrase)
            XCTAssertEqual(session.finishUtterance(at: 4), [], phrase)
        }
    }

    func testSleepCannotReplayConsumedWakePhrase() {
        var session = WakeSession()
        _ = session.receive("Hey Mouse", at: 0)
        XCTAssertEqual(session.receive("Hey Mouse stop listening", at: 1), [.deactivated])
        XCTAssertEqual(session.receive("Hey Mouse stop listening open Safari", at: 2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [])
        XCTAssertEqual(session.receive("Hey Mouse stop listening open Safari hey mouse open Notes", at: 4), [.activated, .partial("open Notes")])
    }

    func testStopInterruptsImmediatelyAndOnlyOnceWhileKeepingActive() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("please stop", at: 60), [.stopped])
        XCTAssertEqual(session.receive("please stop", at: 60.1), [])
        XCTAssertTrue(session.isActive)
        XCTAssertFalse(session.isExecuting)
        XCTAssertEqual(session.finishUtterance(at: 61), [])
        session.beginRecognition()
        XCTAssertEqual(session.receive("open Notes", at: 62), [.partial("open Notes")])
        XCTAssertEqual(session.finishUtterance(at: 63), [.command("open Notes")])
    }

    func testStopPartialCanBecomeStopListeningAfterActionCancellation() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("please stop", at: 2), [.stopped])
        // AppModel synchronously ends execution on interruption. The same speech
        // stream must still be able to complete the longer sleep instruction.
        session.setExecuting(false, at: 2)
        XCTAssertEqual(session.receive("please stop listening", at: 2.2), [.deactivated])
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.finishUtterance(at: 3), [])
    }

    func testRecognitionRecoveryPreservesPartialStopListeningInstruction() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("stop", at: 2), [.stopped])
        session.setExecuting(false, at: 2)
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("listening", at: 2.2), [.deactivated])
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.finishUtterance(at: 3), [])
    }

    func testRecognitionRecoveryPreservesPartialGoToSleepInstruction() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("go to", at: 1), [.partial("go to")])
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("sleep", at: 1.2), [.deactivated])
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.finishUtterance(at: 2), [])
    }

    func testStopListeningCanArriveAsPartialsWhileIdle() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("stop", at: 1), [.stopped])
        XCTAssertEqual(session.receive("stop listening", at: 1.2), [.deactivated])
        XCTAssertFalse(session.isActive)
    }

    func testCancellationRemainderIsNotSubmittedAndNextUtteranceWorks() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("cancel", at: 2), [.stopped])
        XCTAssertEqual(session.receive("cancel that action please", at: 2.1), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [])
        XCTAssertNil(session.lastChangeAt)
        XCTAssertEqual(session.receive("cancel that action please open Notes", at: 4), [.partial("open Notes")])
        XCTAssertEqual(session.finishUtterance(at: 5), [.command("open Notes")])
    }

    func testExecutingDoesNotSubmitAmbientSpeechAndCancelNeedsNoWake() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("open all of my documents", at: 2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [])
        XCTAssertEqual(session.receive("open all of my documents cancel", at: 4), [.stopped])
        XCTAssertTrue(session.isActive)
    }

    func testExecutionCompletionConsumesAmbientSpeechBeforeNextCommand() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("background conversation", at: 2), [])
        session.setExecuting(false, at: 3)
        XCTAssertEqual(session.finishUtterance(at: 4), [])
        XCTAssertEqual(session.receive("background conversation open Notes", at: 5), [.partial("open Notes")])
        XCTAssertEqual(session.finishUtterance(at: 6), [.command("open Notes")])
        XCTAssertTrue(session.isActive)
    }

    func testTypedExecutionCompletionCannotReplayWakeHeardWhileWorking() {
        var session = WakeSession()
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("Hey Mouse open Safari", at: 2), [])
        session.setExecuting(false, at: 3)
        XCTAssertEqual(session.receive("Hey Mouse open Safari now", at: 4), [])
        XCTAssertEqual(session.finishUtterance(at: 5), [])
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.receive("Hey Mouse open Safari now hey mouse open Notes", at: 6), [.activated, .partial("open Notes")])
    }

    func testAllSleepPhrasesWorkDuringExecutionWithoutWakePhrase() {
        for phrase in ["stop listening", "go to sleep", "sleep Mouse"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            session.setExecuting(true, at: 1)
            XCTAssertEqual(session.receive("background words " + phrase, at: 2), [.deactivated], phrase)
            XCTAssertFalse(session.isExecuting, phrase)
            XCTAssertFalse(session.isActive, phrase)
            XCTAssertEqual(session.finishUtterance(at: 3), [], phrase)
        }
    }

    func testStoppingTypedTaskDoesNotActivateStandbySession() {
        var session = WakeSession()
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("stop", at: 2), [.stopped])
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.finishUtterance(at: 3), [])
        session.beginRecognition()
        XCTAssertEqual(session.receive("open Notes", at: 4), [])
    }

    func testActivationSurvivesLongExecutionAndRecognizerRestarts() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.finishUtterance(at: 1_000), [])
        session.setExecuting(false, at: 1_001)
        session.beginRecognition(preservingPending: false)
        XCTAssertEqual(session.receive("open Notes", at: 86_400), [.partial("open Notes")])
        XCTAssertEqual(session.finishUtterance(at: 86_401), [.command("open Notes")])
        XCTAssertTrue(session.isActive)
    }

    func testManualActivationIgnoresEarlierStandbyWords() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("background conversation", at: 0), [])
        XCTAssertEqual(session.activate(at: 1), [.activated])
        XCTAssertEqual(session.receive("background conversation open Safari", at: 2), [.partial("open Safari")])
        XCTAssertEqual(session.finishUtterance(at: 3), [.command("open Safari")])
    }

    func testManualDeactivationDiscardsPendingCommandAndExecution() {
        var session = WakeSession()
        _ = session.receive("Hey Mouse open Safari", at: 0)
        XCTAssertEqual(session.deactivate(), [.deactivated])
        XCTAssertEqual(session.finishUtterance(at: 1), [])
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.pendingCommand, "")
        _ = session.activate(at: 2)
        session.setExecuting(true, at: 3)
        XCTAssertEqual(session.deactivate(), [.deactivated])
        XCTAssertFalse(session.isExecuting)
    }

    func testRecognitionRotationPreservesUnfinishedCommand() {
        var session = WakeSession()
        _ = session.receive("hey mouse search for", at: 0)
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("quiet coffee shops", at: 100), [.partial("search for quiet coffee shops")])
        XCTAssertEqual(session.finishUtterance(at: 101), [.command("search for quiet coffee shops")])
    }

    func testRecognitionRestartCanDiscardTruncatedCommandWithoutDeactivating() {
        var session = WakeSession()
        _ = session.receive("hey mouse search for", at: 0)
        session.beginRecognition(preservingPending: false)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.finishUtterance(at: 100), [])
        XCTAssertEqual(session.receive("open Chrome", at: 101), [.partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 102), [.command("open Chrome")])
    }

    func testARepeatedCommandInANewRecognitionStreamIsAllowed() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        _ = session.receive("scroll down", at: 1)
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("scroll down")])
        session.beginRecognition()
        XCTAssertEqual(session.receive("scroll down", at: 3), [.partial("scroll down")])
        XCTAssertEqual(session.finishUtterance(at: 4), [.command("scroll down")])
    }

    func testSleepWordsInsideARegularCommandDoNotDeactivate() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("search for stop listening lyrics", at: 1), [.partial("search for stop listening lyrics")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("search for stop listening lyrics")])
        XCTAssertTrue(session.isActive)
    }
}
