import XCTest
@testable import ChosenCore

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

    func testWakeRequiresStartButAllowsExplicitPolitePrefixAndLegacyAlias() {
        for text in ["Hey Mouse", "okay hey Mouse", "please hey Mouse", "Hey Chosen"] {
            var session = WakeSession()
            XCTAssertEqual(session.receive(text, at: 0), [.activated], text)
            XCTAssertEqual(session.finishUtterance(at: 1), [], text)
            XCTAssertTrue(session.isActive, text)
        }
    }

    func testOnlyClearCommandPartialsReachUI() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey Mouse", at: 0), [.activated])
        XCTAssertEqual(session.receive("Hey Mouse open", at: 1), [])
        XCTAssertEqual(session.receive("Hey Mouse open Chrome", at: 1.3), [.partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("open Chrome")])
    }

    func testActiveConversationDoesNotProducePartialsOrCommands() {
        for text in ["what is the weather", "how do I open Chrome", "he said open Chrome", "don't open Chrome", "that's interesting", "stop by later"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(text, at: 1), [], text)
            XCTAssertEqual(session.finishUtterance(at: 2), [.ignored], text)
            XCTAssertTrue(session.isActive, text)
        }
    }

    func testQuotedCommandsAndControlsStayIgnoredAfterActivationOrWake() {
        for text in ["\"open Chrome\"", "\"stop listening\""] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(text, at: 1), [], text)
            XCTAssertEqual(session.finishUtterance(at: 2), [.ignored], text)
            XCTAssertTrue(session.isActive, text)
        }
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey Mouse, \"open Chrome\"", at: 0), [.activated])
        XCTAssertEqual(session.finishUtterance(at: 1), [.ignored])
    }

    func testIgnoredSpeechIsNotPrependedToNextCommand() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("what is the weather", at: 1), [])
        XCTAssertEqual(session.finishUtterance(at: 2), [.ignored])
        XCTAssertEqual(session.receive("what is the weather open Chrome", at: 3), [.partial("open Chrome")])
        XCTAssertEqual(session.finishUtterance(at: 4), [.command("open Chrome")])
    }

    func testRecognitionCorrectionRetractsCommandPartialWithoutExecuting() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        XCTAssertEqual(session.receive("open Chrome", at: 1), [.partial("open Chrome")])
        XCTAssertEqual(session.receive("how do I open Chrome", at: 1.2), [.partial("")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.ignored])
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

    func testControlsWaitForCompleteUtteranceAndStopKeepsActivation() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("stop", at: 2), [])
        XCTAssertTrue(session.isExecuting)
        XCTAssertEqual(session.finishUtterance(at: 3), [.stopped])
        XCTAssertFalse(session.isExecuting)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.finishUtterance(at: 4), [])
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

    func testStopListeningWorksAcrossPartialsAndRecognizerRecovery() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("stop", at: 2), [])
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("listening", at: 2.2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [.deactivated])
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isExecuting)
    }

    func testSleepPhrasesReturnToStandbyAfterEndpoint() {
        for phrase in ["stop listening", "go to sleep", "sleep Mouse", "please stop listening"] {
            var session = WakeSession()
            _ = session.activate(at: 0)
            XCTAssertEqual(session.receive(phrase, at: 1), [], phrase)
            XCTAssertEqual(session.finishUtterance(at: 2), [.deactivated], phrase)
            session.beginRecognition()
            XCTAssertEqual(session.receive("open Notes", at: 3), [], phrase)
            XCTAssertEqual(session.finishUtterance(at: 4), [], phrase)
            XCTAssertFalse(session.isActive, phrase)
        }
    }

    func testAmbientExecutionUtteranceIsConsumedBeforeLaterStop() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("background conversation", at: 2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [.ignored])
        XCTAssertEqual(session.receive("background conversation stop", at: 4), [])
        XCTAssertEqual(session.finishUtterance(at: 5), [.stopped])
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
        _ = session.receive("stop listening", at: 2)
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
        XCTAssertEqual(session.finishUtterance(at: 3), [.stopped])
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
        XCTAssertEqual(session.receive("hey mouse search for", at: 0), [.activated])
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
