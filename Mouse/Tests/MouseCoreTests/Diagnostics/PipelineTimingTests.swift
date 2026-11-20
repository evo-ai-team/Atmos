import Foundation
import XCTest
@testable import MouseCore

final class PipelineTimingTests: XCTestCase {
    func testStructuredSnapshotUsesOneClockAndFreezesAfterCompletion() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        let stage = timing.begin("Choose action")
        clock.set(10.5)
        timing.markFirstInput()
        let running = timing.snapshot
        XCTAssertEqual(running.outcome, .running)
        XCTAssertEqual(running.totalDuration, 0.5)
        XCTAssertEqual(running.firstInputDuration, 0.5)
        XCTAssertEqual(running.stages[0].duration, 0.5)
        clock.set(10.75)
        timing.end(stage)
        timing.finish(.succeeded)
        clock.set(30)
        let completed = timing.snapshot
        XCTAssertEqual(completed.totalDuration, 0.75)
        XCTAssertEqual(completed.stages[0].duration, 0.75)
        XCTAssertEqual(completed.stages[0].outcome, .succeeded)
        XCTAssertEqual(completed.outcome, .succeeded)
    }

    func testOverlappingStagesDoNotInflateTotalElapsed() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .speech, clock: { clock.read() })
        let transcription = timing.begin("Transcription")
        clock.set(10.25)
        let capture = timing.begin("Capture")
        clock.set(11)
        timing.end(transcription)
        clock.set(11.25)
        timing.end(capture)
        timing.finish(.succeeded)

        let report = timing.report
        XCTAssertTrue(report.contains("Total elapsed: 1250.0 ms"))
        XCTAssertTrue(report.contains("+0.0 ms · 1000.0 ms · succeeded · Transcription"))
        XCTAssertTrue(report.contains("+250.0 ms · 1000.0 ms · succeeded · Capture"))
        XCTAssertTrue(report.contains("Overlapping stages are not additive"))
    }

    func testFirstInputAttemptIsRecordedOnceAndDoesNotClaimSuccess() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        XCTAssertTrue(timing.report.contains("First input attempt: none"))
        clock.set(10.7)
        timing.markFirstInput()
        clock.set(12)
        timing.markFirstInput()
        timing.finish(.failed)

        XCTAssertTrue(timing.report.contains("First input attempt: 700.0 ms (dispatch attempt, not verified success)"))
        XCTAssertTrue(timing.report.contains("Total elapsed: 2000.0 ms"))
        XCTAssertTrue(timing.report.contains("· typed ·"))
    }

    func testFailureAndCancellationClosePendingSpansAndFreezeTrace() {
        for outcome in [PipelineTiming.Outcome.failed, .cancelled] {
            let clock = TestClock(10)
            let timing = PipelineTiming(origin: .continued, clock: { clock.read() })
            let finished = timing.begin("Finished stage")
            clock.set(10.1)
            timing.end(finished)
            let pending = timing.begin("Pending stage")
            clock.set(11)
            timing.finish(outcome)
            let report = timing.report

            XCTAssertTrue(report.contains("· \(outcome.rawValue)\nTotal elapsed: 1000.0 ms"))
            XCTAssertTrue(report.contains("+100.0 ms · 900.0 ms · \(outcome.rawValue) · Pending stage"))
            XCTAssertTrue(report.contains("+0.0 ms · 100.0 ms · succeeded · Finished stage"))

            clock.set(50)
            timing.end(pending)
            timing.end(timing.begin("Late stage"))
            timing.record("Late interval", from: 10)
            timing.mark("Late event")
            timing.annotate("Late metadata")
            timing.markFirstInput()
            timing.finish(.succeeded)
            XCTAssertEqual(timing.report, report, "Late callbacks must preserve the original evidence")
        }
    }

    func testDuplicateEndAndForeignTraceTokensHaveNoEffect() {
        let clock = TestClock(10)
        let first = PipelineTiming(origin: .speech, clock: { clock.read() })
        let second = PipelineTiming(origin: .speech, clock: { clock.read() })
        let firstSpan = first.begin("Stage")
        let secondSpan = second.begin("Stage")
        clock.set(10.2)
        first.end(firstSpan)
        second.end(firstSpan)
        clock.set(11)
        first.end(firstSpan, outcome: .failed)
        second.end(nil)
        XCTAssertTrue(first.report.contains("+0.0 ms · 200.0 ms · succeeded · Stage"))
        XCTAssertTrue(second.report.contains("+0.0 ms · 1000.0 ms · running · Stage"))
        second.end(secondSpan)
        XCTAssertTrue(second.report.contains("+0.0 ms · 1000.0 ms · succeeded · Stage"))
        XCTAssertNotEqual(first.id, second.id)
    }

    func testReportShowsElapsedTimeForRunningStages() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        let stage = timing.begin("API request")
        clock.set(10.7)
        XCTAssertTrue(timing.report.contains("+0.0 ms · 700.0 ms · running · API request"))
        clock.set(11)
        timing.end(stage)
        clock.set(12)
        XCTAssertTrue(timing.report.contains("Total elapsed: 2000.0 ms"))
        XCTAssertTrue(timing.report.contains("+0.0 ms · 1000.0 ms · succeeded · API request"))
    }

    func testHistoricalIntervalsAndMilestonesUseTraceOffsets() {
        let clock = TestClock(12)
        let timing = PipelineTiming(origin: .speech, startedAt: 10, clock: { clock.read() })
        timing.record("Quiet window", from: 10.5, to: 11)
        let stage = timing.begin("Callback work", at: 11.5)
        timing.mark("Final transcript received")
        clock.set(13)
        timing.end(stage)
        timing.finish(.succeeded)
        XCTAssertTrue(timing.report.contains("Total elapsed: 3000.0 ms"))
        XCTAssertTrue(timing.report.contains("+500.0 ms · 500.0 ms · succeeded · Quiet window"))
        XCTAssertTrue(timing.report.contains("+1500.0 ms · 1500.0 ms · succeeded · Callback work"))
        XCTAssertTrue(timing.report.contains("+2000.0 ms · 0.0 ms · succeeded · Final transcript received"))
    }

    func testBoundedRetentionStillPreservesFirstInputAndTotal() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        for index in 0..<300 {
            timing.mark("Event \(index)")
        }
        clock.set(11)
        timing.markFirstInput()
        timing.finish(.succeeded)
        let report = timing.report
        XCTAssertEqual(stageRows(in: report).count, 256)
        XCTAssertTrue(report.contains("44 additional stage records omitted (limit 256)."))
        XCTAssertTrue(report.contains("First input attempt: 1000.0 ms"))
        XCTAssertTrue(report.contains("Total elapsed: 1000.0 ms"))
        XCTAssertFalse(report.contains("Event 256"))
    }

    func testConcurrentSpansRemainIndependent() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        DispatchQueue.concurrentPerform(iterations: 128) { index in
            let span = timing.begin("Concurrent stage \(index)")
            timing.end(span)
        }
        timing.finish(.succeeded)
        let rows = stageRows(in: timing.report)
        XCTAssertEqual(rows.count, 128)
        XCTAssertTrue(rows.allSatisfy { $0.contains("· succeeded ·") })
        for index in 0..<128 {
            XCTAssertEqual(rows.filter { $0.hasSuffix("Concurrent stage \(index)") }.count, 1)
        }
    }

    func testAnnotationsAreChronologicalMetadataAndDoNotBecomeDurations() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        let request = timing.begin("HTTP request")
        clock.set(10.2)
        timing.annotate("provider processing: 5000 ms")
        timing.record("Earlier callback", from: 10.1, to: 10.15)
        timing.mark("Response received")
        timing.end(request)
        timing.finish(.succeeded)
        // Also test a late callback before the completed report has been cached.
        timing.annotate("Too late")

        let report = timing.report
        let entries = report.split(separator: "\n").filter { $0.hasPrefix("+") || $0.hasPrefix("@+") }
        XCTAssertEqual(entries.count, 4)
        XCTAssertTrue(entries[0].hasSuffix("HTTP request"))
        XCTAssertTrue(entries[1].hasSuffix("Earlier callback"))
        XCTAssertEqual(entries[2], "@+200.0 ms · metadata · provider processing: 5000 ms")
        XCTAssertTrue(entries[3].hasSuffix("Response received"))
        XCTAssertEqual(stageRows(in: report).count, 3)
        XCTAssertTrue(report.contains("Total elapsed: 200.0 ms"))
        XCTAssertFalse(report.contains("Too late"))
        clock.set(50)
        timing.annotate("Also too late")
        XCTAssertEqual(timing.report, report)
    }

    func testMetadataRetentionDoesNotConsumeStageSlotsAndLinesAreBounded() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        timing.annotate("first\nsecond\r\nthird")
        timing.annotate(String(repeating: "x", count: 2000))
        for index in 2..<70 { timing.annotate("Metadata \(index)") }
        for index in 0..<256 { timing.mark("Stage \(index)") }
        timing.finish(.succeeded)

        let report = timing.report
        let metadata = report.split(separator: "\n").filter { $0.hasPrefix("@+") }
        XCTAssertEqual(metadata.count, 64)
        XCTAssertEqual(stageRows(in: report).count, 256)
        XCTAssertTrue(metadata[0].contains("first second"))
        XCTAssertTrue(metadata[0].hasSuffix("third"))
        XCTAssertEqual(metadata[1].filter { $0 == "x" }.count, 1024)
        XCTAssertTrue(report.contains("6 additional metadata annotations omitted (limit 64)."))
        XCTAssertFalse(report.contains("additional stage records omitted"))
        XCTAssertFalse(report.contains("Metadata 64"))
    }

    func testConcurrentAnnotationsRemainIndependentFromSpans() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        DispatchQueue.concurrentPerform(iterations: 64) { index in
            let span = timing.begin("Request \(index)")
            timing.annotate("Response metadata \(index)")
            timing.end(span)
        }
        timing.finish(.succeeded)
        let report = timing.report
        let metadata = report.split(separator: "\n").filter { $0.hasPrefix("@+") }
        XCTAssertEqual(metadata.count, 64)
        XCTAssertEqual(stageRows(in: report).count, 64)
        for index in 0..<64 {
            XCTAssertEqual(metadata.filter { $0.hasSuffix("Response metadata \(index)") }.count, 1)
        }
    }

    func testBackwardAndNonfiniteClockSamplesCannotCorruptDurations() {
        let clock = TestClock(10)
        let timing = PipelineTiming(origin: .typed, clock: { clock.read() })
        let stage = timing.begin("Stage")
        clock.set(11)
        XCTAssertTrue(timing.report.contains("Total elapsed: 1000.0 ms"))
        for invalid in [Double(9), -.infinity, .infinity, .nan] {
            clock.set(invalid)
            XCTAssertTrue(timing.report.contains("Total elapsed: 1000.0 ms"))
        }
        timing.end(stage)
        timing.record("Invalid interval", from: .nan, to: .infinity)
        timing.record("Reversed interval", from: 11, to: 10)
        timing.finish(.succeeded)
        XCTAssertTrue(timing.report.contains("+0.0 ms · 1000.0 ms · succeeded · Stage"))
        XCTAssertTrue(timing.report.contains("+1000.0 ms · 0.0 ms · succeeded · Invalid interval"))
        XCTAssertTrue(timing.report.contains("+1000.0 ms · 0.0 ms · succeeded · Reversed interval"))
    }

    func testInvalidInitialAndHistoricalTimestampsAreBounded() {
        let clock = TestClock(.nan)
        let timing = PipelineTiming(origin: .speech, startedAt: .infinity, clock: { clock.read() })
        XCTAssertTrue(timing.report.contains("Total elapsed: 0.0 ms"))
        clock.set(1)
        timing.record("Before trace", from: -1, to: -1)
        timing.record("Future interval", from: 500, to: 600)
        timing.finish(.succeeded)
        XCTAssertTrue(timing.report.contains("Total elapsed: 1000.0 ms"))
        XCTAssertTrue(timing.report.contains("+1000.0 ms · 0.0 ms · succeeded · Before trace"))
        XCTAssertTrue(timing.report.contains("+1000.0 ms · 0.0 ms · succeeded · Future interval"))
    }

    private func stageRows(in report: String) -> [Substring] {
        report.split(separator: "\n").filter { $0.hasPrefix("+") }
    }
}

/// The clock itself must be safe for the same concurrent callers as the trace.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval

    init(_ value: TimeInterval) { self.value = value }

    func read() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ value: TimeInterval) {
        lock.lock()
        self.value = value
        lock.unlock()
    }
}
