// TESTING BEGIN: offline limits, isolation, and export integrity; no API or UI.
import Foundation
import XCTest
@testable import MouseCore

final class BenchmarkTests: XCTestCase {
    func testRequestCeilingSurvivesTrialsAndDoesNotReserveRejectedAttempt() throws {
        var session = BenchmarkSession(configuration: .init(maximumRequests: 2))
        let first = UUID(), second = UUID()
        try session.begin(id: first, now: 10)
        try session.reserveRequest(id: first, now: 11)
        XCTAssertTrue(session.end(id: first))
        try session.begin(id: second, now: 20)
        try session.reserveRequest(id: second, now: 21)
        XCTAssertThrowsError(try session.reserveRequest(id: second, now: 22)) {
            XCTAssertEqual($0 as? BenchmarkSession.Failure, .requestLimit)
        }
        XCTAssertEqual(session.requestCount, 2)
        XCTAssertTrue(session.end(id: second))
        XCTAssertThrowsError(try session.begin(id: UUID(), now: 23))
    }

    func testDeadlineIncludesSelectionAndRejectsLateRequests() throws {
        var session = BenchmarkSession()
        let id = UUID()
        try session.begin(id: id, now: 100)
        try session.reserveRequest(id: id, now: 129.99)
        XCTAssertThrowsError(try session.reserveRequest(id: id, now: 130)) {
            XCTAssertEqual($0 as? BenchmarkSession.Failure, .deadline)
        }
        XCTAssertEqual(session.requestCount, 1)
    }

    func testSixBatchesAllowTerminalReviewButSeventhDispatchIsRejected() throws {
        var session = BenchmarkSession()
        let id = UUID()
        try session.begin(id: id, now: 0)
        for completed in 0..<6 { try session.check(id: id, now: 1, completedBatches: completed) }
        // Terminal review remains allowed after six dispatches. The owner checks
        // the batch bound only when a response actually requests another batch.
        try session.reserveRequest(id: id, now: 1)
        XCTAssertEqual(session.requestCount, 1)
        XCTAssertThrowsError(try session.check(id: id, now: 1, completedBatches: 6)) {
            XCTAssertEqual($0 as? BenchmarkSession.Failure, .batchLimit)
        }
    }

    func testOldTrialCannotEndOrChargeReplacementAndConcurrentBeginIsRejected() throws {
        var session = BenchmarkSession()
        let old = UUID(), current = UUID()
        try session.begin(id: old, now: 0)
        XCTAssertThrowsError(try session.begin(id: current, now: 1))
        XCTAssertTrue(session.end(id: old))
        try session.begin(id: current, now: 2)
        XCTAssertFalse(session.end(id: old))
        XCTAssertThrowsError(try session.reserveRequest(id: old, now: 3))
        XCTAssertEqual(session.trialID, current)
        XCTAssertEqual(session.requestCount, 0)
    }

    func testReportOmitsEarlierActionsAndFreezesPayloadStatusesAndUsage() throws {
        var history = ActionHistory()
        history.begin(id: UUID(), executionID: UUID(), goal: "Earlier private task", source: "Luna Responses",
                      description: "Typing earlier", action: ComputerAction(type: "type", text: "PRIVATE_PREVIOUS_PAYLOAD"))
        let firstIndex = history.entries.count
        let id = UUID()
        history.begin(id: id, executionID: UUID(), goal: "Current trial", source: "Native accessibility",
                      description: "Clicking Home", action: ComputerAction(type: "click", x: 10, y: 20))
        let timing = PipelineTiming(origin: .typed)
        timing.finish(.cancelled)
        var before = DemoBudget(); before.reserve(); before.record(inputTokens: 100, outputTokens: 5)
        var after = before; after.reserve(); after.record(inputTokens: 80, outputTokens: 2)
        let report = BenchmarkReport(timing: timing, command: "Current trial", behavior: "Luna only", configuration: .init(),
                                     actions: history.entries, firstActionIndex: firstIndex, routes: ["Luna Responses"], before: before, after: after,
                                     cutoffReason: .manualStop, startingContextEntryCount: 3)
        history.finish(id: id)
        let data = try JSONEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("PRIVATE_PREVIOUS_PAYLOAD"))
        XCTAssertFalse(text.contains("Earlier private task"))
        XCTAssertEqual(report.actions.count, 1)
        XCTAssertEqual(report.actions[0].dispatchStatus, "Dispatching")
        XCTAssertEqual(report.usage.attemptedRequests, 1)
        XCTAssertEqual(report.usage.reportedInputTokens, 80)
        XCTAssertEqual(report.usage.reportedOutputTokens, 2)
        XCTAssertEqual(report.outcome, "cancelled")
        XCTAssertEqual(report.cutoffReason, .manualStop)
        XCTAssertEqual(report.startingContextEntryCount, 3)
        XCTAssertTrue(text.contains("manualStop"))
        XCTAssertTrue(report.contextPolicy.contains("original user history is restored"))
        XCTAssertTrue(report.limitation.contains("may omit server work"))
    }

    func testInvalidHistoryBoundaryDoesNotExportOtherCommands() {
        var history = ActionHistory()
        history.begin(id: UUID(), executionID: UUID(), goal: "old", source: "Luna", description: "Typing",
                      action: ComputerAction(type: "type", text: "private"))
        let timing = PipelineTiming(origin: .typed); timing.finish(.failed)
        for invalidIndex in [-1, 2] {
            let report = BenchmarkReport(timing: timing, command: "trial", behavior: "Luna", configuration: .init(),
                                         actions: history.entries, firstActionIndex: invalidIndex, routes: [], before: .init(), after: .init())
            XCTAssertTrue(report.actions.isEmpty)
        }
    }

    func testLimitFailuresHaveDistinctExportReasonsAndConfigurationCannotRaiseCaps() {
        XCTAssertEqual(BenchmarkSession.Failure.deadline.stopReason, .deadline)
        XCTAssertEqual(BenchmarkSession.Failure.batchLimit.stopReason, .batchLimit)
        XCTAssertEqual(BenchmarkSession.Failure.requestLimit.stopReason, .requestLimit)
        XCTAssertNil(BenchmarkSession.Failure.staleTrial.stopReason)
        XCTAssertNil(BenchmarkSession.Failure.alreadyRunning.stopReason)
        let configuration = BenchmarkConfiguration(durationSeconds: .infinity, maximumActionBatches: 20, maximumRequests: 100)
        XCTAssertEqual(configuration.durationSeconds, 30)
        XCTAssertEqual(configuration.maximumActionBatches, 6)
        XCTAssertEqual(configuration.maximumRequests, 30)
    }

    func testRestoringCommandContextKeepsOriginalHistoryIdenticalAcrossTrials() {
        var context = CommandContext()
        let userID = context.begin(command: "Original user command", resolvedGoal: "Original goal")
        context.recordDispatchedAction(id: userID, description: "Clicked original control")
        context.finish(id: userID, outcome: "Original outcome", status: .completed)
        let original = context
        let originalText = context.text
        for status in [CommandContext.Status.paused, .failed, .completed] {
            let trialID = context.begin(command: "Trial command")
            context.recordDispatchedAction(id: trialID, description: "Trial action")
            context.finish(id: trialID, outcome: "Trial outcome", status: status)
            XCTAssertEqual(original.text, originalText)
            context = original
            XCTAssertEqual(context.entries, original.entries)
            XCTAssertEqual(context.text, originalText)
            XCTAssertFalse(context.text.contains("Trial command"))
        }
    }

    func testBenchmarkCapacityRetainsLateMetricsWithoutChangingOrdinaryLimits() {
        let ordinary = PipelineTiming(origin: .typed)
        let benchmark = PipelineTiming(origin: .typed, maximumRecords: 2_048, maximumAnnotations: 512)
        for index in 0..<400 {
            ordinary.mark("Stage \(index)"); benchmark.mark("Stage \(index)")
            ordinary.annotate("Metric \(index)"); benchmark.annotate("Metric \(index)")
        }
        ordinary.finish(.succeeded); benchmark.finish(.succeeded)
        XCTAssertEqual(ordinary.snapshot.stages.count, 256)
        XCTAssertTrue(ordinary.report.contains("additional metadata annotations omitted"))
        XCTAssertEqual(benchmark.snapshot.stages.count, 400)
        XCTAssertTrue(benchmark.report.contains("Metric 399"))
        XCTAssertFalse(benchmark.report.contains("omitted (limit"))
        let frozen = benchmark.report
        benchmark.mark("Late stage"); benchmark.annotate("Late metadata")
        XCTAssertEqual(benchmark.report, frozen)
    }
}
// TESTING END
