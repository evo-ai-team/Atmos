import XCTest
@testable import MouseCore

final class CaptureStampTests: XCTestCase {
    func testCaptureOnlyReusedForSameUtteranceGenerationForegroundAndFreshTime() {
        let utterance = UUID(), generation = UUID()
        let stamp = CaptureStamp(utteranceID: utterance, generation: generation, processID: 42, capturedAt: 10)
        XCTAssertTrue(stamp.canReuse(utteranceID: utterance, generation: generation, processID: 42, now: 10.5))
        XCTAssertFalse(stamp.canReuse(utteranceID: UUID(), generation: generation, processID: 42, now: 10.5))
        XCTAssertFalse(stamp.canReuse(utteranceID: utterance, generation: UUID(), processID: 42, now: 10.5))
        XCTAssertFalse(stamp.canReuse(utteranceID: utterance, generation: generation, processID: 43, now: 10.5))
        for time in [9.9, 11.501, .infinity, .nan] {
            XCTAssertFalse(stamp.canReuse(utteranceID: utterance, generation: generation, processID: 42, now: time))
        }
    }
}
