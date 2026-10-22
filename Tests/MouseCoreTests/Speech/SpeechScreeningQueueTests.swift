import Foundation
import XCTest
@testable import MouseCore

@MainActor
final class SpeechScreeningQueueTests: XCTestCase {
    func testTimingSeparatesQueueWaitFromScreeningAndFollowsEachUtterance() async {
        let firstStarted = expectation(description: "First check starts")
        let secondStarted = expectation(description: "Queued check starts")
        let ignored = expectation(description: "Second utterance ignored")
        let clock = ScreeningTestClock(100)
        let firstTiming = PipelineTiming(origin: .speech, clock: { clock.read() })
        let secondTiming = PipelineTiming(origin: .speech, clock: { clock.read() })
        let firstID = UUID()
        let secondID = UUID()
        let checker = SuspendedSpeechChecker()
        checker.onStart = { ($0 == 1 ? firstStarted : secondStarted).fulfill() }
        var startedIDs: [UUID?] = []
        let queue = SpeechScreeningQueue(check: checker.check, onAccepted: { _, id in
            XCTAssertEqual(id, firstID)
            XCTAssertTrue(firstTiming.report.contains("· running\n"), "Accepted traces continue into computer control")
        }, onIgnored: { id in
            XCTAssertEqual(id, secondID)
            ignored.fulfill()
        }, onFailure: { _, _ in XCTFail("Unexpected failure") }, onCheckStarted: { id, timing in
            startedIDs.append(id)
            XCTAssertTrue(timing === (id == firstID ? firstTiming : secondTiming))
            XCTAssertTrue(timing?.report.contains("· succeeded · Speech screening queue") == true,
                "Queue wait must end before the app starts its checker")
        })

        queue.enqueue("Open Chrome", captureID: firstID, timing: firstTiming)
        queue.enqueue("Background conversation", captureID: secondID, timing: secondTiming)
        await fulfillment(of: [firstStarted], timeout: 2)
        clock.set(101)
        checker.resolve(at: 0, with: .success("Open Chrome"))
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(startedIDs, [firstID, secondID])
        XCTAssertTrue(firstTiming.report.contains("+0.0 ms · 1000.0 ms · succeeded · Speech intent screening"))
        XCTAssertTrue(secondTiming.report.contains("+0.0 ms · 1000.0 ms · succeeded · Speech screening queue"))
        clock.set(101.5)
        checker.resolve(at: 1, with: .success(nil))
        await fulfillment(of: [ignored], timeout: 2)
        XCTAssertTrue(secondTiming.report.contains("· ignored\n"))
        XCTAssertTrue(secondTiming.report.contains("+1000.0 ms · 500.0 ms · succeeded · Speech intent screening"))
        firstTiming.finish(.succeeded)
    }

    func testCancellationClosesCurrentAndQueuedTimingsAndLateResultsCannotChangeThem() async {
        let oldStarted = expectation(description: "Old check starts")
        let newStarted = expectation(description: "Replacement check starts")
        let oldReturned = expectation(description: "Cancelled transport returns")
        let accepted = expectation(description: "Replacement accepted")
        let checker = SuspendedSpeechChecker()
        checker.onStart = { ($0 == 1 ? oldStarted : newStarted).fulfill() }
        checker.onEnd = { if $0 == 0 { oldReturned.fulfill() } }
        let oldTiming = PipelineTiming(origin: .speech)
        let queuedTiming = PipelineTiming(origin: .speech)
        let replacementTiming = PipelineTiming(origin: .speech)
        var queue: SpeechScreeningQueue!
        queue = SpeechScreeningQueue(check: checker.check, onAccepted: { command, _ in
            XCTAssertEqual(command, "Replacement")
            // Reentrant cancellation must not finish the trace just handed off.
            queue.cancel()
            XCTAssertTrue(replacementTiming.report.contains("· running\n"))
            accepted.fulfill()
        }, onIgnored: { _ in XCTFail("Unexpected ignore") }, onFailure: { _, _ in
            XCTFail("Cancelled transports must not report late failures")
        })

        queue.enqueue("Old command", timing: oldTiming)
        queue.enqueue("Queued command", timing: queuedTiming)
        await fulfillment(of: [oldStarted], timeout: 2)
        queue.cancel()
        let oldReport = oldTiming.report
        let queuedReport = queuedTiming.report
        XCTAssertTrue(oldReport.contains("· cancelled · Speech intent screening"))
        XCTAssertTrue(queuedReport.contains("· cancelled · Speech screening queue"))
        queue.enqueue("Replacement", timing: replacementTiming)
        await fulfillment(of: [newStarted], timeout: 2)
        checker.resolve(at: 0, with: .success("Old command"))
        await fulfillment(of: [oldReturned], timeout: 2)
        XCTAssertEqual(oldTiming.report, oldReport)
        XCTAssertEqual(queuedTiming.report, queuedReport)
        XCTAssertTrue(replacementTiming.report.contains("· running · Speech intent screening"))
        checker.resolve(at: 1, with: .success("Replacement"))
        await fulfillment(of: [accepted], timeout: 2)
        replacementTiming.finish(.succeeded)
        queue = nil
    }

    func testWaitsForDecisionThenPassesOnlyExtractedCommandAndCaptureID() async {
        let started = expectation(description: "Screening starts")
        let accepted = expectation(description: "Command accepted")
        let checker = SuspendedSpeechChecker()
        checker.onStart = { _ in started.fulfill() }
        let captureID = UUID()
        let text = String(repeating: "Background conversation. ", count: 200)
            + "Open Chrome, please. The weather sounds nice."
        var acceptedCommands: [String] = []
        let queue = SpeechScreeningQueue(check: checker.check, onAccepted: { command, id in
            acceptedCommands.append(command)
            XCTAssertEqual(id, captureID)
            accepted.fulfill()
        }, onIgnored: { _ in XCTFail("Unexpected ignore") }, onFailure: { _, _ in
            XCTFail("Unexpected failure")
        })

        queue.enqueue(text, captureID: captureID)
        XCTAssertTrue(queue.isScreening)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(checker.calls, [text])
        XCTAssertTrue(acceptedCommands.isEmpty, "Unscreened speech must not interrupt the active task")

        checker.resolve(at: 0, with: .success("Open Chrome, please."))
        await fulfillment(of: [accepted], timeout: 2)
        XCTAssertEqual(acceptedCommands, ["Open Chrome, please."])
        XCTAssertFalse(queue.isScreening)
    }

    func testIgnoreDoesNotAcceptOrChangeIndependentWork() async {
        let started = expectation(description: "Screening starts")
        let ignored = expectation(description: "Background speech ignored")
        let checker = SuspendedSpeechChecker()
        checker.onStart = { _ in started.fulfill() }
        let captureID = UUID()
        var computerTaskContinues = true
        let queue = SpeechScreeningQueue(check: checker.check, onAccepted: { _, _ in
            computerTaskContinues = false
            XCTFail("Background speech must not be accepted")
        }, onIgnored: { id in
            XCTAssertEqual(id, captureID)
            ignored.fulfill()
        }, onFailure: { _, _ in XCTFail("Unexpected failure") })

        queue.enqueue("They said to open Chrome in the video.", captureID: captureID)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(computerTaskContinues)
        checker.resolve(at: 0, with: .success(nil))
        await fulfillment(of: [ignored], timeout: 2)
        XCTAssertTrue(computerTaskContinues)
        XCTAssertFalse(queue.isScreening)
    }

    func testSerializesUtterancesAndReadsLatestContextAtStart() async {
        let firstStarted = expectation(description: "First check starts")
        let secondStarted = expectation(description: "Second check starts")
        let thirdStarted = expectation(description: "Third check starts")
        let finished = expectation(description: "All commands accepted")
        finished.expectedFulfillmentCount = 3
        let starts = [firstStarted, secondStarted, thirdStarted]
        let checker = SuspendedSpeechChecker()
        checker.onStart = { starts[$0 - 1].fulfill() }
        var context = "Opening Chrome"
        var contexts: [String] = []
        var acceptedCommands: [String] = []
        let queue = SpeechScreeningQueue(check: { text in
            contexts.append(context)
            return try await checker.check(text)
        }, onAccepted: { command, _ in
            acceptedCommands.append(command)
            context = command
            finished.fulfill()
        }, onIgnored: { _ in XCTFail("Unexpected ignore") }, onFailure: { _, _ in
            XCTFail("Unexpected failure")
        })

        queue.enqueue("Search YouTube")
        queue.enqueue("Actually search for MKBHD")
        queue.enqueue("Then open his channel")
        await fulfillment(of: [firstStarted], timeout: 2)
        XCTAssertEqual(checker.calls, ["Search YouTube"])
        XCTAssertEqual(contexts, ["Opening Chrome"])

        checker.resolve(at: 0, with: .success("Search YouTube"))
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(contexts, ["Opening Chrome", "Search YouTube"])
        checker.resolve(at: 1, with: .success("Actually search for MKBHD"))
        await fulfillment(of: [thirdStarted], timeout: 2)
        XCTAssertEqual(contexts, ["Opening Chrome", "Search YouTube", "Actually search for MKBHD"])
        checker.resolve(at: 2, with: .success("Then open his channel"))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(acceptedCommands, checker.calls)
        XCTAssertEqual(checker.maximumConcurrentCalls, 1)
        XCTAssertFalse(queue.isScreening)
    }

    func testFailedAndSelfCancelledChecksRetireTheirItemAndContinue() async {
        let firstStarted = expectation(description: "First check starts")
        let secondStarted = expectation(description: "Second check starts")
        let thirdStarted = expectation(description: "Third check starts")
        let finished = expectation(description: "Last command accepted")
        let starts = [firstStarted, secondStarted, thirdStarted]
        let checker = SuspendedSpeechChecker()
        checker.onStart = { starts[$0 - 1].fulfill() }
        let firstID = UUID()
        let secondID = UUID()
        var failures: [(Error, UUID?)] = []
        let queue = SpeechScreeningQueue(check: checker.check, onAccepted: { command, id in
            XCTAssertEqual(command, "Open Calculator")
            XCTAssertNil(id)
            finished.fulfill()
        }, onIgnored: { _ in XCTFail("Unexpected ignore") }, onFailure: { error, id in
            failures.append((error, id))
        })

        queue.enqueue("First utterance", captureID: firstID)
        queue.enqueue("Second utterance", captureID: secondID)
        queue.enqueue("Open Calculator")
        await fulfillment(of: [firstStarted], timeout: 2)
        checker.resolve(at: 0, with: .failure(SuspendedSpeechChecker.Failure.failed))
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(failures.first?.1, firstID)
        checker.resolve(at: 1, with: .failure(CancellationError()))
        await fulfillment(of: [thirdStarted], timeout: 2)
        XCTAssertEqual(failures.count, 2)
        XCTAssertTrue(failures[1].0 is CancellationError)
        XCTAssertEqual(failures[1].1, secondID)
        checker.resolve(at: 2, with: .success("Open Calculator"))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertFalse(queue.isScreening)
    }

    func testCancelDropsQueuedSpeechAndLateAcceptanceWithoutCorruptingNewWorker() async {
        let oldStarted = expectation(description: "Old check starts")
        let newStarted = expectation(description: "New check starts independently")
        let nextStarted = expectation(description: "New queued check starts")
        let oldReturned = expectation(description: "Cancelled check returns late")
        let finished = expectation(description: "New commands accepted")
        finished.expectedFulfillmentCount = 2
        let starts = [oldStarted, newStarted, nextStarted]
        let checker = SuspendedSpeechChecker()
        checker.onStart = { starts[$0 - 1].fulfill() }
        checker.onEnd = { index in if index == 0 { oldReturned.fulfill() } }
        var acceptedCommands: [String] = []
        let queue = SpeechScreeningQueue(check: checker.check, onAccepted: { command, _ in
            acceptedCommands.append(command)
            finished.fulfill()
        }, onIgnored: { _ in XCTFail("Unexpected ignore") }, onFailure: { _, _ in
            XCTFail("Cancelled checks must not report late failures")
        })

        queue.enqueue("Old command")
        queue.enqueue("Old queued command")
        await fulfillment(of: [oldStarted], timeout: 2)
        queue.cancel()
        XCTAssertFalse(queue.isScreening)
        queue.enqueue("New command")
        await fulfillment(of: [newStarted], timeout: 2)
        checker.resolve(at: 0, with: .success("Old command"))
        await fulfillment(of: [oldReturned], timeout: 2)
        XCTAssertTrue(acceptedCommands.isEmpty)
        XCTAssertTrue(queue.isScreening)

        queue.enqueue("New next command")
        XCTAssertEqual(checker.calls, ["Old command", "New command"])
        checker.resolve(at: 1, with: .success("New command"))
        await fulfillment(of: [nextStarted], timeout: 2)
        checker.resolve(at: 2, with: .success("New next command"))
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(checker.calls, ["Old command", "New command", "New next command"])
        XCTAssertEqual(acceptedCommands, ["New command", "New next command"])
        XCTAssertFalse(queue.isScreening)
    }

    func testCancelSuppressesLateFailureAndSynchronousCallbackCanReplaceQueue() async {
        let firstStarted = expectation(description: "First check starts")
        let replacementStarted = expectation(description: "Replacement starts")
        let replacementReturned = expectation(description: "Cancelled replacement fails late")
        let starts = [firstStarted, replacementStarted]
        let checker = SuspendedSpeechChecker()
        checker.onStart = { starts[$0 - 1].fulfill() }
        checker.onEnd = { index in if index == 1 { replacementReturned.fulfill() } }
        var acceptedCommands: [String] = []
        var queue: SpeechScreeningQueue!
        queue = SpeechScreeningQueue(check: checker.check, onAccepted: { command, _ in
            acceptedCommands.append(command)
            queue.cancel()
            queue.enqueue("Replacement")
        }, onIgnored: { _ in XCTFail("Unexpected ignore") }, onFailure: { _, _ in
            XCTFail("Cancelled checks must not report late failures")
        })

        queue.enqueue("First command")
        queue.enqueue("Stale queued command")
        await fulfillment(of: [firstStarted], timeout: 2)
        checker.resolve(at: 0, with: .success("First command"))
        await fulfillment(of: [replacementStarted], timeout: 2)
        XCTAssertEqual(checker.calls, ["First command", "Replacement"])
        XCTAssertTrue(queue.isScreening)
        queue.cancel()
        checker.resolve(at: 1, with: .failure(SuspendedSpeechChecker.Failure.failed))
        await fulfillment(of: [replacementReturned], timeout: 2)
        XCTAssertEqual(acceptedCommands, ["First command"])
        XCTAssertFalse(queue.isScreening)
        queue = nil
    }
}

/// A controlled monotonic clock keeps queue-duration assertions independent of
/// scheduling speed while satisfying the trace's thread-safe clock contract.
private final class ScreeningTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval
    init(_ time: TimeInterval) { self.time = time }
    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return time
    }
    func set(_ time: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.time = time
    }
}

@MainActor
private final class SuspendedSpeechChecker {
    enum Failure: Error { case failed }
    private(set) var calls: [String] = []
    private(set) var maximumConcurrentCalls = 0
    private var concurrentCalls = 0
    private var continuations: [Int: CheckedContinuation<String?, Error>] = [:]
    var onStart: ((Int) -> Void)?
    var onEnd: ((Int) -> Void)?

    // Intentionally ignores cancellation so tests can return a stale network
    // result after Stop, including while a replacement worker is already running.
    func check(_ text: String) async throws -> String? {
        let index = calls.count
        calls.append(text)
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
        defer {
            concurrentCalls -= 1
            onEnd?(index)
        }
        return try await withCheckedThrowingContinuation { continuation in
            continuations[index] = continuation
            onStart?(calls.count)
        }
    }

    func resolve(at index: Int, with result: Result<String?, Error>) {
        guard let continuation = continuations.removeValue(forKey: index) else {
            XCTFail("No suspended check at index \(index)")
            return
        }
        continuation.resume(with: result)
    }
}
