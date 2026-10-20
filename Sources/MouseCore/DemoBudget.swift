import Foundation

/// Persistent usage counters, independent of the provider's billing controls.
/// Requests are counted before networking, including failed/cancelled attempts.
public struct DemoBudget: Codable, Sendable {
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    private var accumulatedEstimate: Double?
    public init() {}
    public mutating func reserve() {
        requests = Self.adding(1, to: requests)
    }
    public mutating func record(_ turn: ModelTurn) {
        record(inputTokens: turn.inputTokens, outputTokens: turn.outputTokens)
    }
    public mutating func record(inputTokens input: Int, outputTokens output: Int) {
        let previous = estimatedUSD
        inputTokens = Self.adding(input, to: inputTokens)
        outputTokens = Self.adding(output, to: outputTokens)
        accumulatedEstimate = previous + Self.estimate(input: input, output: output)
    }
    public var estimatedUSD: Double {
        if let accumulatedEstimate, accumulatedEstimate.isFinite, accumulatedEstimate >= 0 { return accumulatedEstimate }
        // Existing files contain only totals, accumulated with the old Luna rate.
        return Double(max(0, inputTokens)) * 0.20 / 1_000_000 + Double(max(0, outputTokens)) / 1_000_000
    }

    /// Luna Fast rates per million tokens, checked 2026-10-19. This is an estimate:
    /// cache discounts/writes and regional premiums are not represented. Already
    /// accumulated estimates from earlier routing are preserved without repricing.
    private static func estimate(input: Int, output: Int) -> Double {
        let longContext = input > 272_000
        return (Double(max(0, input)) * 0.20 * (longContext ? 2 : 1)
            + Double(max(0, output)) * (longContext ? 1.5 : 1)) / 1_000_000
    }

    private static func adding(_ amount: Int, to total: Int) -> Int {
        let (result, overflow) = max(0, total).addingReportingOverflow(max(0, amount))
        return overflow ? .max : result
    }
}
