import Foundation

/// Persistent usage counters, independent of the provider's billing controls.
/// Requests are counted before networking, including failed/cancelled attempts.
public struct DemoBudget: Codable, Sendable {
    public static let stepsPerCommand = 8
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public init() {}
    public mutating func reserve() {
        requests = Self.adding(1, to: requests)
    }
    public mutating func record(_ turn: ModelTurn) {
        inputTokens = Self.adding(turn.inputTokens, to: inputTokens)
        outputTokens = Self.adding(turn.outputTokens, to: outputTokens)
    }
    public var estimatedUSD: Double { Double(inputTokens) * 0.20 / 1_000_000 + Double(outputTokens) * 1.00 / 1_000_000 }

    private static func adding(_ amount: Int, to total: Int) -> Int {
        let (result, overflow) = max(0, total).addingReportingOverflow(max(0, amount))
        return overflow ? .max : result
    }
}
