import Foundation

/// Persistent usage counters, independent of the provider's billing controls.
/// Requests are counted before networking, including failed/cancelled attempts.
public struct DemoBudget: Codable, Sendable {
    /// Price each completed call at its own endpoint's rate. Token totals alone
    /// cannot reconstruct a session that mixes selection and generated actions.
    public enum Rate: Sendable {
        case responses
        case decisions
    }

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
    public mutating func record(inputTokens input: Int, outputTokens output: Int, rate: Rate = .responses) {
        let previous = estimatedUSD
        inputTokens = Self.adding(input, to: inputTokens)
        outputTokens = Self.adding(output, to: outputTokens)
        accumulatedEstimate = previous + Self.estimate(input: input, output: output, rate: rate)
    }
    public var estimatedUSD: Double {
        if let accumulatedEstimate, accumulatedEstimate.isFinite, accumulatedEstimate >= 0 { return accumulatedEstimate }
        // Existing files contain only totals, accumulated with the old Luna rate.
        return Double(max(0, inputTokens)) * 0.20 / 1_000_000 + Double(max(0, outputTokens)) / 1_000_000
    }

    /// Responses retains the existing Luna Fast estimate; Decisions charges
    /// $0.10 per million input tokens and no output charge (checked 2026-10-20).
    /// Long-context premiums apply per request, not to the lifetime counter.
    /// Cache discounts/writes and regional premiums are not represented. Stored
    /// estimates are preserved: switching routes never reprices earlier calls.
    private static func estimate(input: Int, output: Int, rate: Rate) -> Double {
        let longContext = input > 272_000
        switch rate {
        case .responses:
            return (Double(max(0, input)) * 0.20 * (longContext ? 2 : 1)
                + Double(max(0, output)) * (longContext ? 1.5 : 1)) / 1_000_000
        case .decisions:
            return Double(max(0, input)) * 0.10 * (longContext ? 2 : 1) / 1_000_000
        }
    }

    private static func adding(_ amount: Int, to total: Int) -> Int {
        let (result, overflow) = max(0, total).addingReportingOverflow(max(0, amount))
        return overflow ? .max : result
    }
}
