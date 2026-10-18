import XCTest
@testable import MouseCore

final class WakeSessionTests: XCTestCase {
    func testStandbyIgnoresOrdinaryReportedAndQuotedSpeech() {
        for text in ["open Chrome", "he said hey Mouse open Chrome", "don't say hey Mouse", "they chose an excellent option", "hey mousy open Safari", "\"hey Mouse open Chrome\""] {
            var session = WakeSession()
            XCTAssertEqual(session.receive(text, at: 0), [], text)
            XCTAssertEqual(session.finishUtterance(at: 1), [], text)
            XCTAssertFalse(session.isActive, text)
        }
    }

    func testStandbyConsumesBackgroundUtteranceBeforeARealWake() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("he said hey Mouse", at: 0), [])
        XCTAssertEqual(session.finishUtterance(at: 1), [])
        XCTAssertEqual(session.receive("he said hey Mouse hey Mouse open Chrome", at: 2), [.activated, .partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 3), [.command("open Chrome")])
    }

    func testWakeRequiresStartButAllowsExplicitPolitePrefix() {
        for text in ["Hey Mouse", "okay hey Mouse", "please hey Mouse"] {
            var session = WakeSession()
            XCTAssertEqual(session.receive(text, at: 0), [.activated], text)
            XCTAssertEqual(session.finishUtterance(at: 1), [], text)
            XCTAssertTrue(session.isActive, text)
        }
    }

    func testFormerWakeNameDoesNotActivateOrStripOrdinarySpeech() {
        for text in ["Hey Chosen", "Hey Chosen, open Chrome", "okay hey Chosen open Chrome"] {
            var standby = WakeSession()
            XCTAssertEqual(standby.receive(text, at: 0), [], text)
            XCTAssertEqual(standby.finishUtterance(at: 1), [], text)
            XCTAssertFalse(standby.isActive, text)

            var active = WakeSession()
            _ = active.activate(at: 0)
            XCTAssertEqual(active.receive(text, at: 1), [.partial(text)], text)
            XCTAssertEqual(active.finishUtterance(at: 2), [.command(text)], text)
        }
    }

    func testLivePartialsReachUIWhileTheUtteranceIsStillIncomplete() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey Mouse", at: 0), [.activated])
        XCTAssertEqual(session.receive("Hey Mouse open", at: 1), [.partial("open")])
        XCTAssertEqual(session.receive("Hey Mouse open Chrome", at: 1.3), [.partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("open Chrome")])
    }

    func testEveryActiveIdleUtteranceReachesModelUnchanged() {
        for text in ["what is the weather?", "how do I open Chrome", "he said open Chrome", "don't open Chrome", "that's interesting", "stop by later", "Could you bring the spreadsheet I was just working on back?", "Put that over there", "Launch ImaginaryApp", "open", "I wonder whether this will work."] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(text, at: 1), [.partial(text)], text)
            XCTAssertEqual(session.finishUtterance(at: 2), [.command(text)], text)
            XCTAssertTrue(session.isActive, text)
        }
    }

    func testQuotedUtterancesReachModelInsteadOfMatchingLocalControls() {
        for text in ["\"open Chrome\"", "\"stop listening\"", "\"stop\"", "(stop)"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(text, at: 1), [.partial(text)], text)
            XCTAssertEqual(session.finishUtterance(at: 2), [.command(text)], text)
            XCTAssertTrue(session.isActive, text)
        }
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey Mouse, \"open Chrome\"", at: 0), [.activated, .partial("\"open Chrome\"")])
        XCTAssertEqual(session.finishUtterance(at: 1), [.command("\"open Chrome\"")])
    }

    func testCompletedUtteranceIsNotPrependedToNextOne() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("what is the weather", at: 1), [.partial("what is the weather")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("what is the weather")])
        XCTAssertEqual(session.receive("what is the weather open Chrome", at: 3), [.partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 4), [.command("open Chrome")])
    }

    func testRecognitionCorrectionReplacesLiveTextAndSubmitsCorrectedUtterance() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("open Chrome", at: 1), [.partial("open Chrome")])
        XCTAssertEqual(session.receive("how do I open Chrome", at: 1.2), [.partial("how do I open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("how do I open Chrome")])
    }

    func testRepeatedPartialsAndFinalResultDoNotResubmit() {
        var session = WakeSession()
        _ = session.receive("Hey Mouse open Safari", at: 0)
        XCTAssertEqual(session.receive("Hey Mouse open Safari", at: 0.2), [])
        XCTAssertEqual(session.finishUtterance(at: 1), [.command("open Safari")])
        XCTAssertEqual(session.receive("Hey Mouse open Safari.", at: 1.2), [])
        XCTAssertEqual(session.finishUtterance(at: 2), [])
    }

    func testActivationPersistsForHoursAndAcrossExecution() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        session.beginRecognition(preservingPending: true)
        session.setExecuting(false, at: 1_000)
        session.beginRecognition(preservingPending: false)
        XCTAssertEqual(session.receive("open Notes", at: 86_400), [.partial("open Notes")])
        XCTAssertEqual(session.finishUtterance(at: 86_401), [.command("open Notes")])
        XCTAssertTrue(session.isActive)
    }

    func testCancelIsNotALocalControlWhileExecuting() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("cancel", at: 2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [.ignored])
        XCTAssertTrue(session.isExecuting)
        XCTAssertTrue(session.isActive)
    }

    func testStopSleepsAfterEndpointAndRequiresWakeForNextCommand() {
        for executing in [false, true] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            session.setExecuting(executing, at: 1)
            XCTAssertEqual(session.receive("stop", at: 2), [])
            XCTAssertTrue(session.isActive)
            XCTAssertEqual(session.finishUtterance(at: 3), [.deactivated])
            XCTAssertFalse(session.isActive)
            XCTAssertFalse(session.isExecuting)
            session.beginRecognition()
            XCTAssertEqual(session.receive("open Chrome", at: 4), [])
            XCTAssertEqual(session.finishUtterance(at: 5), [])
            session.beginRecognition()
            XCTAssertEqual(session.receive("Hey Mouse open Chrome", at: 6), [.activated, .partial("open Chrome")])
            XCTAssertEqual(session.finishUtterance(at: 7), [.command("open Chrome")])
        }
    }

    func testFalseControlPhrasesNeverCancelOrSleepDuringExecution() {
        for text in ["stop by later", "don't stop", "cancel my dinner reservation", "stop listening to that story", "he said stop", "we should go to sleep soon"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            session.setExecuting(true, at: 1)
            XCTAssertEqual(session.receive(text, at: 2), [], text)
            XCTAssertEqual(session.finishUtterance(at: 3), [.ignored], text)
            XCTAssertTrue(session.isExecuting, text)
            XCTAssertTrue(session.isActive, text)
        }
    }

    func testStopPartialCanFinishAsCasualSpeechWithoutCancelling() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("stop", at: 2), [])
        XCTAssertEqual(session.receive("stop by later", at: 2.1), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [.ignored])
        XCTAssertTrue(session.isExecuting)
    }

    func testStopListeningIsNotInterceptedAcrossPartialsAndRecovery() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("stop", at: 1), [])
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("listening", at: 1.2), [.partial("stop listening")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("stop listening")])
        XCTAssertTrue(session.isActive)
    }

    func testFormerControlPhrasesAreOrdinaryModelUtterances() {
        for text in ["cancel", "cancel that", "sleep", "go to sleep", "stop listening", "sleep Mouse", "please stop", "stop now"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(text, at: 1), [.partial(text)], text)
            XCTAssertEqual(session.finishUtterance(at: 2), [.command(text)], text)
            XCTAssertTrue(session.isActive, text)
        }
    }

    func testWakePhraseFollowedByBareStopSleepsLocally() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey Mouse stop", at: 1), [.activated])
        XCTAssertEqual(session.finishUtterance(at: 2), [.deactivated])
        XCTAssertFalse(session.isActive)
    }

    func testWakePrefixIsStrippedForBareStopDuringExecution() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("Hey Mouse stop", at: 2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [.deactivated])
        XCTAssertFalse(session.isExecuting)
        XCTAssertFalse(session.isActive)
    }

    func testAmbientExecutionUtteranceIsConsumedBeforeLaterStop() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("background conversation", at: 2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [.ignored])
        XCTAssertEqual(session.receive("background conversation stop", at: 4), [])
        XCTAssertEqual(session.finishUtterance(at: 5), [.deactivated])
    }

    func testExecutionCompletionConsumesAmbientSpeechBeforeNextCommand() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        _ = session.receive("background conversation", at: 2)
        session.setExecuting(false, at: 3)
        XCTAssertEqual(session.finishUtterance(at: 4), [])
        XCTAssertEqual(session.receive("background conversation open Notes", at: 5), [.partial("open Notes")])
        XCTAssertEqual(session.finishUtterance(at: 6), [.command("open Notes")])
    }

    func testExecutionCompletionDoesNotDropPendingSleepInstruction() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        _ = session.receive("stop", at: 2)
        session.setExecuting(false, at: 2.1)
        XCTAssertEqual(session.finishUtterance(at: 3), [.deactivated])
    }

    func testTypedExecutionCannotActivateWithWakeHeardDuringTask() {
        var session = WakeSession()
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("Hey Mouse open Safari", at: 2), [])
        session.setExecuting(false, at: 3)
        XCTAssertEqual(session.receive("Hey Mouse open Safari now", at: 4), [])
        XCTAssertEqual(session.finishUtterance(at: 5), [])
        XCTAssertFalse(session.isActive)
    }

    func testStoppingTypedTaskDoesNotActivateStandby() {
        var session = WakeSession()
        session.setExecuting(true, at: 1)
        _ = session.receive("stop", at: 2)
        XCTAssertEqual(session.finishUtterance(at: 3), [.deactivated])
        XCTAssertFalse(session.isActive)
    }

    func testTypingOrSearchingControlWordsIsStillAComputerCommand() {
        for text in ["type stop listening", "search for why did you stop", "search for how do I open Chrome"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(text, at: 1), [.partial(text)], text)
            XCTAssertEqual(session.finishUtterance(at: 2), [.command(text)], text)
            XCTAssertTrue(session.isActive, text)
        }
    }

    func testRecognitionRotationPreservesUnfinishedCommand() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("hey mouse search for", at: 0), [.activated, .partial("search for")])
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("quiet coffee shops", at: 1), [.partial("search for quiet coffee shops")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("search for quiet coffee shops")])
    }

    func testRecognitionRotationPreservesSplitWakePhrase() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("hey", at: 0), [])
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("Mouse open Chrome", at: 0.2), [.activated, .partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 1), [.command("open Chrome")])
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

    func testManualDeactivationDiscardsPendingCommand() {
        var session = WakeSession()
        _ = session.receive("Hey Mouse open Chrome", at: 0)
        XCTAssertEqual(session.deactivate(), [.deactivated])
        XCTAssertEqual(session.finishUtterance(at: 1), [])
        XCTAssertFalse(session.isActive)
    }
}
