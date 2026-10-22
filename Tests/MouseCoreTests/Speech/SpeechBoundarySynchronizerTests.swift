import XCTest
@testable import MouseCore

@MainActor
final class SpeechBoundarySynchronizerTests: XCTestCase {
    func testCoalescesTargetsAndNeverFinalizesConcurrently() async {
        let first = expectation(description: "First boundary starts")
        let second = expectation(description: "Coalesced boundary starts")
        let finalizer = SuspendedFinalizer()
        finalizer.onStart = { count in (count == 1 ? first : second).fulfill() }
        let synchronizer = SpeechBoundarySynchronizer(finalize: finalizer.finalize) { _ in XCTFail("Unexpected failure") }

        synchronizer.request(through: 1)
        synchronizer.request(through: 2)
        synchronizer.request(through: 3)
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(finalizer.calls, [3])

        synchronizer.request(through: 4)
        synchronizer.request(through: 8)
        synchronizer.request(through: 5)
        XCTAssertEqual(finalizer.calls, [3])
        finalizer.succeed()
        await fulfillment(of: [second], timeout: 2)
        XCTAssertEqual(finalizer.calls, [3, 8])
        XCTAssertEqual(synchronizer.completedThrough, 3)

        finalizer.succeed()
        await synchronizer.awaitIdle()
        XCTAssertEqual(synchronizer.completedThrough, 8)
        XCTAssertEqual(finalizer.maximumConcurrentCalls, 1)
    }

    func testIgnoresInvalidAndAlreadyCompletedBoundaries() async {
        let started = expectation(description: "Valid boundary starts")
        let finalizer = SuspendedFinalizer()
        finalizer.onStart = { _ in started.fulfill() }
        let synchronizer = SpeechBoundarySynchronizer(finalize: finalizer.finalize) { _ in XCTFail("Unexpected failure") }

        for boundary in [TimeInterval.nan, .infinity, -.infinity, -1, 0] {
            synchronizer.request(through: boundary)
        }
        await synchronizer.awaitIdle()
        XCTAssertTrue(finalizer.calls.isEmpty)

        synchronizer.request(through: 4)
        await fulfillment(of: [started], timeout: 2)
        finalizer.succeed()
        await synchronizer.awaitIdle()
        for boundary in [TimeInterval.nan, .infinity, -1, 0, 2, 4] {
            synchronizer.request(through: boundary)
        }
        await synchronizer.awaitIdle()
        XCTAssertEqual(finalizer.calls, [4])
        XCTAssertEqual(synchronizer.completedThrough, 4)
    }

    func testCancelReleasesIdleWaiterAndIgnoresLateSuccess() async {
        let started = expectation(description: "Old analyzer starts")
        let ended = expectation(description: "Old analyzer returns after cancellation")
        let idle = expectation(description: "Cancellation releases idle waiter")
        let finalizer = SuspendedFinalizer()
        finalizer.onStart = { _ in started.fulfill() }
        finalizer.onEnd = { ended.fulfill() }
        var failureCount = 0
        let synchronizer = SpeechBoundarySynchronizer(finalize: finalizer.finalize) { _ in failureCount += 1 }

        synchronizer.request(through: 1)
        await fulfillment(of: [started], timeout: 2)
        synchronizer.request(through: 5)
        let waiter = Task { @MainActor in
            await synchronizer.awaitIdle()
            idle.fulfill()
        }
        await Task.yield()
        synchronizer.cancel()
        synchronizer.request(through: 6)
        await fulfillment(of: [idle], timeout: 2)
        await waiter.value
        finalizer.succeed()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(finalizer.calls, [1])
        XCTAssertEqual(synchronizer.completedThrough, 0)
        XCTAssertEqual(failureCount, 0)
    }

    func testCancelSuppressesFailureFromOldWorker() async {
        let started = expectation(description: "Old analyzer starts")
        let ended = expectation(description: "Old analyzer fails after cancellation")
        let finalizer = SuspendedFinalizer()
        finalizer.onStart = { _ in started.fulfill() }
        finalizer.onEnd = { ended.fulfill() }
        var failureCount = 0
        let synchronizer = SpeechBoundarySynchronizer(finalize: finalizer.finalize) { _ in failureCount += 1 }

        synchronizer.request(through: 1)
        await fulfillment(of: [started], timeout: 2)
        synchronizer.cancel()
        finalizer.fail()
        await fulfillment(of: [ended], timeout: 2)
        await synchronizer.awaitIdle()
        XCTAssertEqual(synchronizer.completedThrough, 0)
        XCTAssertEqual(failureCount, 0)
    }

    func testFailureReportsOnceAndRetiresPendingWork() async {
        let started = expectation(description: "Boundary starts")
        let finalizer = SuspendedFinalizer()
        finalizer.onStart = { _ in started.fulfill() }
        var errors: [Error] = []
        let synchronizer = SpeechBoundarySynchronizer(finalize: finalizer.finalize) { errors.append($0) }

        synchronizer.request(through: 2)
        await fulfillment(of: [started], timeout: 2)
        synchronizer.request(through: 9)
        finalizer.fail()
        await synchronizer.awaitIdle()
        synchronizer.request(through: 12)
        await synchronizer.awaitIdle()
        XCTAssertEqual(finalizer.calls, [2])
        XCTAssertEqual(synchronizer.completedThrough, 0)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first is SuspendedFinalizer.Failure)
    }
}

@MainActor
private final class SuspendedFinalizer {
    enum Failure: Error { case failed }
    private(set) var calls: [TimeInterval] = []
    private(set) var maximumConcurrentCalls = 0
    private var concurrentCalls = 0
    private var continuations: [CheckedContinuation<Void, Error>] = []
    var onStart: ((Int) -> Void)?
    var onEnd: (() -> Void)?

    // Deliberately ignores task cancellation, modeling an operation whose work
    // can finish after its owner has retired the analyzer lifecycle.
    func finalize(through boundary: TimeInterval) async throws {
        calls.append(boundary)
        concurrentCalls += 1
        maximumConcurrentCalls = max(maximumConcurrentCalls, concurrentCalls)
        defer {
            concurrentCalls -= 1
            onEnd?()
        }
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
            onStart?(calls.count)
        }
    }

    func succeed() {
        guard !continuations.isEmpty else { XCTFail("No suspended finalization"); return }
        continuations.removeFirst().resume()
    }

    func fail() {
        guard !continuations.isEmpty else { XCTFail("No suspended finalization"); return }
        continuations.removeFirst().resume(throwing: Failure.failed)
    }
}
