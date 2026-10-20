import XCTest
@testable import MouseCore

final class DemoBudgetTests: XCTestCase {
    func testLegacyTokenOnlyUsageMigratesWithoutLosingCounts() throws {
        let data = Data(#"{"requests":502,"inputTokens":1000000,"outputTokens":1000000}"#.utf8)
        var usage = try JSONDecoder().decode(DemoBudget.self, from: data)
        XCTAssertEqual(usage.estimatedUSD, 1.2, accuracy: 0.000001)
        usage.record(inputTokens: 1000, outputTokens: 100)
        XCTAssertEqual(usage.estimatedUSD, 1.2003, accuracy: 0.000001)
        let restored = try JSONDecoder().decode(DemoBudget.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(restored.estimatedUSD, usage.estimatedUSD)
        XCTAssertEqual(restored.requests, 502)
        XCTAssertEqual(restored.inputTokens, 1001000)
    }
    func testReturningToLunaPreservesEarlierMixedModelEstimate() throws {
        // Stored costs can include former Decisions/Astra requests. Do not
        // reprice those historical tokens when only Luna is used from now on.
        let data = Data(#"{"requests":1047,"inputTokens":1002000,"outputTokens":1000100,"accumulatedEstimate":1.2301}"#.utf8)
        var usage = try JSONDecoder().decode(DemoBudget.self, from: data)
        usage.reserve()
        usage.record(ModelTurn(id: "luna", calls: [], inputTokens: 1000, outputTokens: 100))
        let restored = try JSONDecoder().decode(DemoBudget.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(restored.requests, 1048)
        XCTAssertEqual(restored.inputTokens, 1003000)
        XCTAssertEqual(restored.outputTokens, 1000200)
        XCTAssertEqual(restored.estimatedUSD, 1.2304, accuracy: 0.000001)
    }
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
