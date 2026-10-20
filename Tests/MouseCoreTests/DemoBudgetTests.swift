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
    func testResponsesCallPreservesEarlierMixedModelEstimate() throws {
        // Stored costs can include any earlier routing. Adding a new Responses
        // call must not reprice those historical tokens.
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
    func testMixedRoutesKeepTheirOwnRatesAcrossLaunches() throws {
        var usage = DemoBudget()
        usage.reserve()
        usage.record(inputTokens: 1000, outputTokens: 100, rate: .responses)
        usage.reserve()
        usage.record(inputTokens: 2000, outputTokens: 10, rate: .decisions)
        var restored = try JSONDecoder().decode(DemoBudget.self, from: JSONEncoder().encode(usage))
        restored.reserve()
        restored.record(inputTokens: 1000, outputTokens: 100)
        XCTAssertEqual(restored.requests, 3)
        XCTAssertEqual(restored.inputTokens, 4000)
        XCTAssertEqual(restored.outputTokens, 210)
        XCTAssertEqual(restored.estimatedUSD, 0.0008, accuracy: 0.000000001)
    }
    func testDecisionsCallMigratesLegacyTotalsWithoutRepricingThem() throws {
        let data = Data(#"{"requests":502,"inputTokens":1000000,"outputTokens":1000000}"#.utf8)
        var usage = try JSONDecoder().decode(DemoBudget.self, from: data)
        usage.record(inputTokens: 1000, outputTokens: 0, rate: .decisions)
        XCTAssertEqual(usage.estimatedUSD, 1.2001, accuracy: 0.000001)
        let restored = try JSONDecoder().decode(DemoBudget.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(restored.estimatedUSD, usage.estimatedUSD)
        XCTAssertEqual(restored.requests, 502)
        XCTAssertEqual(restored.inputTokens, 1001000)
        XCTAssertEqual(restored.outputTokens, 1000000)
    }
    func testDecisionsOutputTokensAreCountedButNotCharged() {
        var usage = DemoBudget()
        usage.record(inputTokens: 1000, outputTokens: 1_000_000, rate: .decisions)
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 1_000_000)
        XCTAssertEqual(usage.estimatedUSD, 0.0001, accuracy: 0.000000001)
    }
    func testDecisionsLongContextPremiumAppliesPerCallAboveThreshold() {
        var usage = DemoBudget()
        usage.record(inputTokens: 272_000, outputTokens: 0, rate: .decisions)
        XCTAssertEqual(usage.estimatedUSD, 0.0272, accuracy: 0.000000001)
        // The cumulative counter is now large, but this small call is still
        // charged at the normal rate. Only an individual large call doubles it.
        usage.record(inputTokens: 1000, outputTokens: 0, rate: .decisions)
        XCTAssertEqual(usage.estimatedUSD, 0.0273, accuracy: 0.000000001)
        usage.record(inputTokens: 272_001, outputTokens: 0, rate: .decisions)
        XCTAssertEqual(usage.estimatedUSD, 0.0817002, accuracy: 0.000000001)
    }
    func testNegativeUsageCannotReduceCountsOrCost() {
        var usage = DemoBudget()
        usage.record(inputTokens: 1000, outputTokens: 100)
        usage.record(inputTokens: -1000, outputTokens: -100, rate: .decisions)
        usage.record(inputTokens: -1000, outputTokens: -100, rate: .responses)
        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertEqual(usage.estimatedUSD, 0.0003, accuracy: 0.000000001)
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
        usage.record(inputTokens: .max, outputTokens: .max, rate: .decisions)
        XCTAssertEqual(usage.requests, .max)
        XCTAssertEqual(usage.inputTokens, .max)
        XCTAssertEqual(usage.outputTokens, .max)
        XCTAssertTrue(usage.estimatedUSD.isFinite)
    }
}
