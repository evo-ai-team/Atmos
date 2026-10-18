import XCTest
@testable import MouseCore

final class DemoBudgetTests: XCTestCase {
    func testRequestsContinueBeyondOneHundredAcrossLaunches() throws {
        var usage = DemoBudget()
        for _ in 0..<150 { usage.reserve() }
        var restored = try JSONDecoder().decode(DemoBudget.self, from: JSONEncoder().encode(usage))
        restored.reserve()
        XCTAssertEqual(restored.requests, 151)
    }
    func testAttemptsWithoutReturnedUsageStillCount() {
        var usage = DemoBudget()
        // Failed and cancelled requests contribute attempts even without a ModelTurn.
        usage.reserve()
        usage.reserve()
        usage.reserve()
        usage.record(ModelTurn(id: "test", calls: [], inputTokens: 1000, outputTokens: 100))
        XCTAssertEqual(usage.requests, 3)
        XCTAssertEqual(usage.estimatedUSD, 0.0003, accuracy: 0.000001)
    }
    func testExtremeStoredTotalsCannotOverflowAndBlockARequest() {
        var usage = DemoBudget()
        usage.requests = .max
        usage.inputTokens = .max
        usage.outputTokens = .max
        usage.reserve()
        usage.record(ModelTurn(id: "test", calls: [], inputTokens: 10, outputTokens: 10))
        XCTAssertEqual(usage.requests, .max)
        XCTAssertEqual(usage.inputTokens, .max)
        XCTAssertEqual(usage.outputTokens, .max)
        XCTAssertTrue(usage.estimatedUSD.isFinite)
    }
}
