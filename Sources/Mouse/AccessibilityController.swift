import AppKit
import ApplicationServices
#if SWIFT_PACKAGE
import MouseCore
#endif

/// AX calls synchronously message another process. Keeping them on this actor
/// prevents an unresponsive browser from blocking microphone/UI work on MainActor.
/// Each message and the complete walk have separate, short time budgets.
actor AccessibilityController {
    private enum Limits {
        static let elements = 220
        static let children = 48
        static let depth = 14
        static let text = 320
        static let captureSeconds = 0.75
        static let messageSeconds = 0.05
    }
    private static let supportedActions: Set<String> = ["AXPress", "AXShowMenu", "AXIncrement", "AXDecrement"]
    private struct Target {
        let reference: AXUIElement
        let element: AccessibilityElement
        let fullLabel: String?
    }
    private struct ReadElement {
        let element: AccessibilityElement
        let fullLabel: String?
    }
    private struct Pending {
        let reference: AXUIElement
        let id: String
        let parentID: String?
        let depth: Int
    }
    private struct Budget {
        let deadline: TimeInterval
        var reasons: Set<String> = []
        mutating func prepare(_ reference: AXUIElement) throws {
            try Task.checkCancellation()
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw ReadFailure.deadline }
            AXUIElementSetMessagingTimeout(reference, Float(min(Limits.messageSeconds, remaining)))
        }
    }
    private enum ReadFailure: Error { case deadline }
    private var snapshotID: UUID?
    private var snapshotProcessID: Int32?
    private var snapshotWindow: AXUIElement?
    private var targets: [String: Target] = [:]

    func capture(processID: Int32, frame: ScreenshotFrame) async throws -> AccessibilitySnapshot {
        try Task.checkCancellation()
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        try Task.checkCancellation()
        let id = UUID()
        snapshotID = id; snapshotProcessID = processID; snapshotWindow = nil
        targets.removeAll(keepingCapacity: true)
        var snapshot = AccessibilitySnapshot(id: id, processID: processID, elements: [])
        guard AXIsProcessTrusted() else {
            snapshot.unavailableReason = "Accessibility permission is unavailable."
            return snapshot
        }
        guard processID > 0, frontmost == processID else {
            snapshot.unavailableReason = "The requested application is no longer frontmost."
            return snapshot
        }

        var budget = Budget(deadline: ProcessInfo.processInfo.systemUptime + Limits.captureSeconds)
        let application = AXUIElementCreateApplication(processID)
        var queue: [Pending] = []
        var visited: [CFHashCode: [AXUIElement]] = [:]
        func enqueue(_ reference: AXUIElement, parentID: String?, depth: Int) -> Bool {
            let hash = CFHash(reference)
            guard visited[hash]?.contains(where: { CFEqual($0, reference) }) != true else { return false }
            guard queue.count < Limits.elements else { return false }
            visited[hash, default: []].append(reference)
            queue.append(Pending(reference: reference, id: "e\(queue.count + 1)", parentID: parentID, depth: depth))
            return true
        }

        do {
            // A full application tree can include every background window. Start
            // with the current window and menu bar, then breadth-first walk their
            // descendants so a deeply nested web page cannot starve all controls.
            let roots = try attributes(application, names: [kAXFocusedWindowAttribute, kAXMainWindowAttribute, kAXMenuBarAttribute], budget: &budget)
            snapshotWindow = element(roots[kAXFocusedWindowAttribute]) ?? element(roots[kAXMainWindowAttribute])
            if let focused = snapshotWindow {
                _ = enqueue(focused, parentID: nil, depth: 0)
            }
            if let menu = element(roots[kAXMenuBarAttribute]) { _ = enqueue(menu, parentID: nil, depth: 0) }
            if queue.isEmpty {
                snapshot.unavailableReason = "The frontmost application exposed no focused/main window or menu bar."
            }
            var index = 0
            while index < queue.count {
                let pending = queue[index]
                index += 1
                guard let readResult = try read(pending.reference, id: pending.id, parentID: pending.parentID,
                                                frame: frame, budget: &budget) else { continue }
                var record = readResult.element
                // Never walk beneath a password field: some custom controls put
                // their actual content in descendants rather than AXValue.
                if !record.secure {
                    let children = try children(pending.reference, budget: &budget)
                    record.childCount = children.total
                    record.childrenTruncated = children.truncated
                    if pending.depth >= Limits.depth, !children.references.isEmpty {
                        record.childrenTruncated = true
                        budget.reasons.insert("depth_limit")
                    } else {
                        for child in children.references {
                            if queue.count >= Limits.elements {
                                record.childrenTruncated = true
                                budget.reasons.insert("element_limit")
                                break
                            }
                            _ = enqueue(child, parentID: record.id, depth: pending.depth + 1)
                        }
                    }
                }
                snapshot.elements.append(record)
                targets[record.id] = Target(reference: pending.reference, element: record, fullLabel: readResult.fullLabel)
            }
        } catch ReadFailure.deadline {
            budget.reasons.insert("time_limit")
        }
        try Task.checkCancellation()

        // Construct links only after the walk: a deadline or inaccessible child
        // must not leave IDs in the JSON that have no corresponding element.
        let groups = Dictionary(grouping: snapshot.elements.compactMap { item in
            item.parentID.map { ($0, item.id) }
        }, by: { $0.0 })
        for index in snapshot.elements.indices {
            let itemID = snapshot.elements[index].id
            snapshot.elements[index].childIDs = groups[itemID, default: []].map { $0.1 }
            if let count = snapshot.elements[index].childCount, count > snapshot.elements[index].childIDs.count {
                snapshot.elements[index].childrenTruncated = true
                budget.reasons.insert("shared_or_skipped_children")
            }
        }
        snapshot.rootIDs = snapshot.elements.filter { $0.parentID == nil }.map(\.id)
        snapshot.truncationReasons = budget.reasons.sorted()
        snapshot.truncated = !budget.reasons.isEmpty
        if snapshot.elements.isEmpty, snapshot.unavailableReason == nil {
            snapshot.unavailableReason = "The application did not return readable accessibility elements within the capture budget."
        }
        return snapshot
    }

    /// Perform one observed semantic action, never a fresh search by label. AX
    /// IDs are snapshot-scoped and consumed after any attempted action, including
    /// a timeout: that timeout can mean the action happened but its reply was late.
    func perform(action: String, targetID: String, snapshotID requestedID: UUID, processID: Int32) async throws {
        try Task.checkCancellation()
        guard Self.supportedActions.contains(action) else {
            throw MouseError.invalidAction("Unsupported accessibility action: \(action).")
        }
        let frontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier }
        guard snapshotID == requestedID, snapshotProcessID == processID,
              let target = targets[targetID], frontmost == processID else {
            throw MouseError.invalidAction("The accessibility target is stale. Capture a new tree before acting.")
        }
        let capturedWindow = snapshotWindow
        guard AXIsProcessTrusted() else { throw MouseError.permission("Accessibility permission is unavailable.") }
        var targetPID: pid_t = 0
        guard AXUIElementGetPid(target.reference, &targetPID) == .success, targetPID == processID else {
            throw MouseError.invalidAction("The accessibility target no longer belongs to the captured application.")
        }
        guard !target.element.secure, target.element.enabled == true, target.element.actions.contains(action) else {
            throw MouseError.invalidAction("The captured target does not expose this enabled accessibility action.")
        }
        var budget = Budget(deadline: ProcessInfo.processInfo.systemUptime + 0.35)
        let currentRead: ReadElement?
        do { currentRead = try read(target.reference, id: targetID, parentID: target.element.parentID, frame: nil, budget: &budget) }
        catch ReadFailure.deadline { throw MouseError.invalidAction("The target could not be revalidated in time. Capture a new tree.") }
        guard let currentRead else { throw MouseError.invalidAction("The accessibility target is no longer readable.") }
        let current = currentRead.element
        guard !current.secure, current.enabled == true, current.actions.contains(action),
              current.role == target.element.role, current.subrole == target.element.subrole,
              currentRead.fullLabel == target.fullLabel, current.screenBounds == target.element.screenBounds else {
            throw MouseError.invalidAction("The accessibility target changed. Capture a new tree before acting.")
        }
        let stillFrontmost = await MainActor.run { NSWorkspace.shared.frontmostApplication?.processIdentifier == processID }
        // This await can allow another capture into the actor. Recheck snapshot
        // identity after MainActor work, and do not yield again before dispatch.
        try Task.checkCancellation()
        guard stillFrontmost, AXIsProcessTrusted(), snapshotID == requestedID else {
            throw MouseError.invalidAction("Accessibility context changed before dispatch.")
        }
        // A PID remains the same when the user switches between an app's windows.
        // Old AX handles can still press controls in the obscured window, so keep
        // the captured focused/main window identity as part of the action context.
        var windowBudget = Budget(deadline: ProcessInfo.processInfo.systemUptime + 0.1)
        let windowAttributes = try attributes(AXUIElementCreateApplication(processID),
                                              names: [kAXFocusedWindowAttribute, kAXMainWindowAttribute],
                                              budget: &windowBudget, requireReliableValues: true)
        let currentWindow = element(windowAttributes[kAXFocusedWindowAttribute]) ?? element(windowAttributes[kAXMainWindowAttribute])
        let sameWindow: Bool
        switch (capturedWindow, currentWindow) {
        case let (captured?, current?): sameWindow = CFEqual(captured, current)
        case (nil, nil): sameWindow = true // Some applications expose only a menu bar.
        default: sameWindow = false
        }
        guard sameWindow, !windowBudget.reasons.contains("unreadable_attributes") else {
            throw MouseError.invalidAction("The focused window changed or could not be verified. Capture a new tree before acting.")
        }
        try Task.checkCancellation()
        AXUIElementSetMessagingTimeout(target.reference, 0.15)
        snapshotID = nil; snapshotWindow = nil; targets.removeAll(keepingCapacity: true)
        let result = AXUIElementPerformAction(target.reference, action as CFString)
        guard result == .success else {
            throw MouseError.invalidAction("Accessibility action returned \(result.rawValue); its effect is uncertain. Observe the screen before deciding whether another action is needed.")
        }
    }

    private func read(_ reference: AXUIElement, id: String, parentID: String?, frame: ScreenshotFrame?,
                      budget: inout Budget) throws -> ReadElement? {
        // Read protection metadata before requesting anything that could contain
        // user text. AX error wrappers and object descriptions are never sent.
        let identity = try attributes(reference, names: [kAXRoleAttribute, kAXSubroleAttribute], budget: &budget,
                                      requireReliableValues: true)
        guard let role = identity[kAXRoleAttribute] as? String else {
            budget.reasons.insert("unreadable_elements")
            return nil
        }
        let subrole = identity[kAXSubroleAttribute] as? String
        let secure = role == "AXSecureTextField" || subrole == "AXSecureTextField"
        let geometryNames = [kAXPositionAttribute, kAXSizeAttribute, kAXEnabledAttribute]
        let names = secure ? geometryNames : geometryNames + [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute, kAXHelpAttribute]
        let details = try attributes(reference, names: names, budget: &budget)
        let bounds = bounds(details)
        let enabled = details[kAXEnabledAttribute] as? Bool
        // The model receives bounded strings; stale-target checks retain the full
        // label so a changed suffix cannot slip past the prompt's text limit.
        let fullLabel = secure ? nil : scalarText(details[kAXTitleAttribute]) ?? scalarText(details[kAXDescriptionAttribute])
        let label = text(fullLabel, budget: &budget)
        let actions = secure ? [] : try actionNames(reference, budget: &budget)
        let record = AccessibilityElement(id: id, parentID: parentID, role: role, subrole: subrole,
                                          label: label, value: secure ? nil : text(details[kAXValueAttribute], budget: &budget),
                                          help: secure ? nil : text(details[kAXHelpAttribute], budget: &budget),
                                          enabled: enabled, actions: actions, screenBounds: bounds,
                                          screenshotBounds: frame.flatMap { bounds?.screenshotBounds(in: $0) }, secure: secure)
        return ReadElement(element: record, fullLabel: fullLabel)
    }

    private func attributes(_ reference: AXUIElement, names: [String], budget: inout Budget,
                            requireReliableValues: Bool = false) throws -> [String: Any] {
        try budget.prepare(reference)
        var values: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(reference, names as CFArray, [], &values)
        guard result == .success, let array = values as? [Any], array.count == names.count else {
            budget.reasons.insert("unreadable_attributes")
            return [:]
        }
        var output: [String: Any] = [:]
        for (name, value) in zip(names, array) {
            let object = value as CFTypeRef
            if CFGetTypeID(object) == CFNullGetTypeID() { continue }
            if CFGetTypeID(object) == AXValueGetTypeID(), AXValueGetType(object as! AXValue) == .axError {
                var error = AXError.success
                AXValueGetValue(object as! AXValue, .axError, &error)
                if error != .attributeUnsupported && error != .noValue {
                    budget.reasons.insert("unreadable_attributes")
                    // A failed subrole read must not cause a secure field to be
                    // mistaken for an ordinary text field on the next request.
                    if requireReliableValues { return [:] }
                }
                continue
            }
            output[name] = value
        }
        return output
    }

    private func actionNames(_ reference: AXUIElement, budget: inout Budget) throws -> [String] {
        try budget.prepare(reference)
        var names: CFArray?
        let result = AXUIElementCopyActionNames(reference, &names)
        guard result == .success, let actions = names as? [String] else {
            if result != .notImplemented && result != .noValue { budget.reasons.insert("unreadable_actions") }
            return []
        }
        return actions.filter { Self.supportedActions.contains($0) }.sorted()
    }

    private func children(_ reference: AXUIElement, budget: inout Budget) throws -> (references: [AXUIElement], total: Int?, truncated: Bool) {
        try budget.prepare(reference)
        var count = 0
        let countResult = AXUIElementGetAttributeValueCount(reference, kAXChildrenAttribute as CFString, &count)
        guard countResult == .success else {
            let incomplete = countResult != .attributeUnsupported && countResult != .noValue
            if incomplete { budget.reasons.insert("unreadable_children") }
            return ([], nil, incomplete)
        }
        guard count > 0 else { return ([], 0, false) }
        try budget.prepare(reference)
        var values: CFArray?
        let result = AXUIElementCopyAttributeValues(reference, kAXChildrenAttribute as CFString, 0, min(count, Limits.children), &values)
        guard result == .success, let children = values as? [Any] else {
            budget.reasons.insert("unreadable_children")
            return ([], count, true)
        }
        let references = children.compactMap(element)
        let incomplete = count > references.count
        if incomplete { budget.reasons.insert("children_limit_or_unreadable") }
        return (references, count, incomplete)
    }

    private func element(_ value: Any?) -> AXUIElement? {
        guard let value else { return nil }
        let object = value as CFTypeRef
        guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
        return (object as! AXUIElement)
    }

    private func bounds(_ attributes: [String: Any]) -> AccessibilityBounds? {
        guard let rawPosition = attributes[kAXPositionAttribute], let rawSize = attributes[kAXSizeAttribute],
              CFGetTypeID(rawPosition as CFTypeRef) == AXValueGetTypeID(),
              CFGetTypeID(rawSize as CFTypeRef) == AXValueGetTypeID() else { return nil }
        let positionValue = rawPosition as! AXValue, sizeValue = rawSize as! AXValue
        guard AXValueGetType(positionValue) == .cgPoint, AXValueGetType(sizeValue) == .cgSize else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        let bounds = AccessibilityBounds(x: point.x, y: point.y, width: size.width, height: size.height)
        return bounds.isValid ? bounds : nil
    }

    private func scalarText(_ value: Any?) -> String? {
        let string: String
        if let value = value as? String { string = value }
        else if let value = value as? NSNumber { string = value.stringValue }
        else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func text(_ value: Any?, budget: inout Budget) -> String? {
        guard let string = scalarText(value) else { return nil }
        if string.count > Limits.text { budget.reasons.insert("text_limit") }
        return String(string.prefix(Limits.text))
    }
}
