import Foundation

/// In-memory diagnostics for the inputs actually sent to an executor. Unlike
/// task context, this history survives goal changes so the Actions tab can show
/// the model's description beside the exact payload that was dispatched.
public struct ActionHistory: Sendable {
    public enum Status: String, Sendable {
        case dispatching = "Dispatching"
        case dispatched = "Dispatched"
        case uncertain = "Uncertain"
    }

    /// A native accessibility operation has a snapshot-scoped target, not a
    /// generated coordinate click. Preserve that distinction in the visible log.
    public struct NativeTarget: Encodable, Sendable {
        public let action: String
        public let elementID: String
        public let snapshotID: UUID
        public let role: String
        public let label: String?
        public let screenBounds: AccessibilityBounds?

        public init(action: String, elementID: String, snapshotID: UUID, role: String,
                    label: String? = nil, screenBounds: AccessibilityBounds? = nil) {
            self.action = action
            self.elementID = elementID
            self.snapshotID = snapshotID
            self.role = role
            self.label = label
            self.screenBounds = screenBounds
        }
    }

    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let recordedAt: Date
        public let goal: String
        public let source: String
        public let description: String
        public let payloadJSON: String
        public fileprivate(set) var status: Status
        public fileprivate(set) var detail: String?
        fileprivate let executionID: UUID
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    /// Call immediately before dispatch, using the same ID as task steering.
    /// No proposed actions are added here; text and coordinates remain complete.
    public mutating func begin(id: UUID, executionID: UUID, goal: String, source: String,
                               description: String, action: ComputerAction,
                               nativeTarget: NativeTarget? = nil) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        // Even malformed coordinates should be inspectable if dispatch fails.
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        // Both payload types use synthesized encoding of JSON-supported fields.
        let data = nativeTarget.map { try! encoder.encode($0) } ?? (try! encoder.encode(action))
        entries.append(Entry(
            id: id, recordedAt: Date(), goal: goal, source: source,
            description: description, payloadJSON: String(decoding: data, as: UTF8.self),
            status: .dispatching, detail: nil, executionID: executionID
        ))
    }

    /// Confirms only that dispatch finished, not that its intended UI effect did.
    /// A late executor return must not erase an earlier interruption.
    public mutating func finish(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].status == .dispatching else { return }
        entries[index].status = .dispatched
    }

    public mutating func markUncertain(id: UUID, detail: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }),
              entries[index].status == .dispatching else { return }
        entries[index].status = .uncertain
        entries[index].detail = detail
    }

    /// An old execution can finish cancelling after a new one starts. Scope the
    /// uncertainty to its own inputs rather than changing the new task's log.
    public mutating func markUnfinishedUncertain(executionID: UUID) {
        for index in entries.indices
        where entries[index].executionID == executionID && entries[index].status == .dispatching {
            entries[index].status = .uncertain
            entries[index].detail = "Execution ended before dispatch completion was confirmed."
        }
    }
}
