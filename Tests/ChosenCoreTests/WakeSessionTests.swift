import XCTest
@testable import ChosenCore

final class WakeSessionTests: XCTestCase {
    func testStandbyNeverEmitsCommandForOrdinarySpeechOrPhoneticLookalikes() {
        for transcript in ["Open Safari", "they chose an excellent option", "a chosen one", "hey Chosenly open Safari"] {
            var session = WakeSession()
            XCTAssertEqual(session.receive(transcript, at: 0), [])
            XCTAssertEqual(session.finishUtterance(at: 1), [])
            XCTAssertFalse(session.isActive)
        }
    }

    func testWakePhraseWaitsForCommandAndKeepsFullCumulativePartial() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("Hey, Chosen!", at: 0), [.activated])
        XCTAssertEqual(session.finishUtterance(at: 0.8), [])
        XCTAssertEqual(session.receive("Hey, Chosen! Open", at: 1), [.partial("Open")])
        XCTAssertEqual(session.receive("Hey, Chosen! Open Safari", at: 1.3), [.partial("Open Safari")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("Open Safari")])
    }

    func testRepeatedPartialsAndFinalResultDoNotResubmit() {
        var session = WakeSession()
        _ = session.receive("Hey Chosen open Safari", at: 0)
        XCTAssertEqual(session.receive("Hey Chosen open Safari", at: 0.2), [])
        XCTAssertEqual(session.finishUtterance(at: 1), [.command("open Safari")])
        XCTAssertEqual(session.receive("Hey Chosen open Safari.", at: 1.2), [])
        XCTAssertEqual(session.finishUtterance(at: 2), [])
        XCTAssertEqual(session.receive("Hey Chosen open Safari now search for cats", at: 3), [.partial("now search for cats")])
        XCTAssertEqual(session.finishUtterance(at: 4), [.command("now search for cats")])
    }

    func testFollowUpAcceptsCommandWithoutWakeAndExpiresAtTwentySeconds() {
        var session = WakeSession()
        _ = session.receive("Hey Chosen", at: 0)
        session.beginRecognition()
        XCTAssertEqual(session.receive("open Safari", at: 5), [.partial("open Safari")])
        XCTAssertEqual(session.finishUtterance(at: 6), [.command("open Safari")])
        session.beginRecognition()
        XCTAssertEqual(session.expire(at: 25.9), [])
        XCTAssertEqual(session.expire(at: 26), [.expired])
        XCTAssertEqual(session.receive("open Notes", at: 27), [])
        XCTAssertEqual(session.finishUtterance(at: 28), [])
        XCTAssertFalse(session.isActive)
    }

    func testExpiredCumulativeWakePhraseDoesNotReactivate() {
        var session = WakeSession()
        _ = session.receive("Hey Chosen", at: 0)
        XCTAssertEqual(session.expire(at: 20), [.expired])
        XCTAssertEqual(session.receive("Hey Chosen open Safari", at: 21), [])
        XCTAssertEqual(session.receive("Hey Chosen open Safari hey chosen open Notes", at: 22), [.activated, .partial("open Notes")])
    }

    func testStopInterruptsImmediatelyAndOnlyOnceDuringExecution() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.expire(at: 60), [])
        XCTAssertEqual(session.receive("please stop", at: 60), [.stopped])
        XCTAssertEqual(session.receive("please stop", at: 60.1), [])
        XCTAssertEqual(session.finishUtterance(at: 61), [])
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isExecuting)
    }

    func testExecutingDoesNotSubmitAmbientSpeechAndCancelNeedsNoWake() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.receive("open all of my documents", at: 2), [])
        XCTAssertEqual(session.finishUtterance(at: 3), [])
        XCTAssertEqual(session.receive("open all of my documents cancel", at: 4), [.stopped])
    }

    func testFollowUpWindowStartsAgainAfterLongExecution() {
        var session = WakeSession()
        _ = session.activate(at: 0)
        session.setExecuting(true, at: 1)
        XCTAssertEqual(session.expire(at: 100), [])
        session.setExecuting(false, at: 100)
        XCTAssertEqual(session.expire(at: 119.9), [])
        XCTAssertEqual(session.expire(at: 120), [.expired])
    }

    func testPushToTalkIgnoresEarlierStandbyWords() {
        var session = WakeSession()
        XCTAssertEqual(session.receive("background conversation", at: 0), [])
        XCTAssertEqual(session.activate(at: 1), [.activated])
        XCTAssertEqual(session.receive("background conversation open Safari", at: 2), [.partial("open Safari")])
        XCTAssertEqual(session.finishUtterance(at: 3), [.command("open Safari")])
    }

    func testRecognitionRotationPreservesUnfinishedCommand() {
        var session = WakeSession()
        _ = session.receive("hey chosen search for", at: 0)
        session.beginRecognition(preservingPending: true)
        XCTAssertEqual(session.receive("quiet coffee shops", at: 1), [.partial("search for quiet coffee shops")])
        XCTAssertEqual(session.finishUtterance(at: 2), [.command("search for quiet coffee shops")])
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
}
