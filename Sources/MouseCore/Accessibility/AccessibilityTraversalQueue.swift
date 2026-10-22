/// A bounded walk that keeps window content ahead of unopened menu contents.
/// Capacity includes processed nodes: a wide, low-priority branch cannot reserve
/// every remaining slot before a deeper window control has been discovered.
public struct AccessibilityTraversalQueue<Value> {
    public enum Priority: Int {
        case menuContents, window, content, menuBar, root
    }
    public enum Admission {
        case accepted
        case replaced(Value)
        case rejected
    }
    private struct Entry {
        let value: Value
        let priority: Priority
    }
    private let limit: Int
    private var pending: [Entry] = []
    public private(set) var processedCount = 0
    public private(set) var omittedCount = 0

    // Modern windows can expose hundreds of shallow navigation controls before
    // their content. The AX reader also enforces its independent 750 ms budget.
    public init(limit: Int = 600) { self.limit = max(0, limit) }

    /// A readable page, list, document, or editor often sits below many ordinary
    /// app controls. Once reached, keep descending through its layout wrappers
    /// before shallow navigation siblings can exhaust the remaining slots.
    public static func isContentRegion(role: String, inherited: Bool) -> Bool {
        inherited || ["AXWebArea", "AXScrollArea", "AXOutline", "AXTable", "AXTextArea"].contains(role)
    }

    /// Evict only pending, lower-priority work. The caller can release its native
    /// handle and remove it from deduplication, allowing a later useful discovery.
    public mutating func enqueue(_ value: Value, priority: Priority) -> Admission {
        var replaced: Value?
        if processedCount + pending.count >= limit {
            guard let lowest = pending.map({ $0.priority.rawValue }).min(), lowest < priority.rawValue,
                  let index = pending.lastIndex(where: { $0.priority.rawValue == lowest }) else {
                omittedCount += 1
                return .rejected
            }
            replaced = pending.remove(at: index).value
            omittedCount += 1
        }
        pending.append(Entry(value: value, priority: priority))
        return replaced.map(Admission.replaced) ?? .accepted
    }

    public mutating func next() -> Value? {
        guard let highest = pending.map({ $0.priority.rawValue }).max(),
              let index = pending.firstIndex(where: { $0.priority.rawValue == highest }) else { return nil }
        processedCount += 1
        return pending.remove(at: index).value
    }
}
