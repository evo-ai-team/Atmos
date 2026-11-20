import Foundation

/// A model may name a captured element, never a native AX handle or a label to
/// search again. The snapshot ID prevents an old e-number targeting a new tree.
public struct AccessibilityAction: Codable, Equatable, Sendable {
    public static let supportedActions = ["AXPress", "AXShowMenu", "AXIncrement", "AXDecrement"]

    public let snapshotID: UUID
    public let elementID: String
    public let action: String

    public init(snapshotID: UUID, elementID: String, action: String) {
        self.snapshotID = snapshotID
        self.elementID = elementID
        self.action = action
    }

    enum CodingKeys: String, CodingKey {
        case snapshotID = "snapshot_id", elementID = "element_id", action
    }

    /// Validate model output against the exact observation that was sent. The
    /// native controller separately rechecks the live app/window and target.
    public func resolve(in snapshot: AccessibilitySnapshot) throws -> AccessibilityElement {
        guard snapshotID == snapshot.id, Self.supportedActions.contains(action),
              let element = snapshot.nativeActionElements.first(where: { $0.id == elementID }),
              element.actions.contains(action) else {
            throw MouseError.invalidAction("The accessibility action does not match an enabled, visible target in the current snapshot. No new input was sent.")
        }
        return element
    }
}

extension AccessibilitySnapshot {
    /// Both planners share the same eligibility rules. Unknown enabled state,
    /// duplicate IDs and missing/offscreen geometry cannot identify a target.
    public var nativeActionElements: [AccessibilityElement] {
        guard unavailableReason == nil else { return [] }
        let groups = Dictionary(grouping: elements, by: \.id)
        return elements.filter { element in
            guard !element.id.isEmpty, groups[element.id]?.count == 1,
                  element.enabled == true, !element.secure,
                  !element.role.localizedCaseInsensitiveContains("secure"),
                  element.subrole?.localizedCaseInsensitiveContains("secure") != true,
                  let bounds = element.screenshotBounds, bounds.isValid,
                  bounds.x >= 0, bounds.y >= 0 else { return false }
            return element.actions.contains { AccessibilityAction.supportedActions.contains($0) }
        }
    }
}
