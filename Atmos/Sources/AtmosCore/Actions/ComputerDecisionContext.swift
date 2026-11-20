import Foundation

/// Text-only evidence for choosing a known operation. The planner retains the
/// complete history, action payloads, accessibility tree, and screenshot.
public struct ComputerDecisionContext: Encodable, Sendable {
    public let request: String?
    public let isContinuation: Bool
    public let goal: String?
    public let recentCommands: [RecentCommand]
    public let omittedCommandCount: Int
    public let recentAnswers: [RecentAnswer]
    public let omittedAnswerCount: Int
    public let progress: [Dispatch]
    public let omittedDispatchCount: Int
    public let pendingClarification: String?
    public let ui: UIEvidence

    /// Missing or entirely filtered evidence cannot authorize completion. Even
    /// when true, only positive UI state can establish that the goal is complete.
    public var hasUIEvidence: Bool { !ui.unavailable && !ui.elements.isEmpty }

    public init(request: String, isContinuation: Bool, task: TaskSteeringState?,
                recentCommands: [CommandContext.Entry], pendingClarification: String?,
                recentAnswers: [CommandContext.QuestionExchange] = [],
                snapshot: AccessibilitySnapshot) {
        // A continuation already supplies the complete goal below. Do not send
        // a second copy as though it were a new utterance to interpret.
        self.request = isContinuation && request == task?.goal ? nil : request
        self.isContinuation = isContinuation
        // Never summarize or clip accepted intent, including ordered amendments.
        goal = task?.goal
        self.recentCommands = recentCommands.suffix(3).map(RecentCommand.init)
        omittedCommandCount = max(0, recentCommands.count - self.recentCommands.count)
        self.recentAnswers = recentAnswers.suffix(3).map(RecentAnswer.init)
        omittedAnswerCount = max(0, recentAnswers.count - self.recentAnswers.count)
        progress = task.map { task in
            task.dispatched.suffix(12).map {
                Dispatch(type: $0.action.type, description: $0.description,
                         result: $0.result, belongsToCurrentTask: task.belongsToCurrentTask($0))
            }
        } ?? []
        omittedDispatchCount = max(0, (task?.dispatched.count ?? 0) - progress.count)
        self.pendingClarification = pendingClarification
        ui = UIEvidence(snapshot)
    }

    /// The selector only needs to recognize a conversational follow-up. Luna
    /// receives the full replies when a question refers to details omitted here.
    public struct RecentAnswer: Encodable, Sendable {
        public let question: String
        public let brief: String
        public let afterCommandCount: Int

        fileprivate init(_ exchange: CommandContext.QuestionExchange) {
            question = exchange.question
            brief = exchange.brief
            afterCommandCount = exchange.afterCommandCount
        }
    }

    public struct RecentCommand: Encodable, Sendable {
        public let command: String
        public let resolvedGoal: String?
        public let lastDispatched: String?
        public let status: CommandContext.Status
        public let outcome: String?

        fileprivate init(_ entry: CommandContext.Entry) {
            command = entry.command
            resolvedGoal = entry.resolvedGoal == entry.command ? nil : entry.resolvedGoal
            lastDispatched = entry.lastDispatchedActionDescription
            status = entry.status
            outcome = entry.outcome
        }
    }

    /// Dispatch completion means the input was sent, not that its effect worked.
    /// Coordinates, keys, typed text, and old copies of the goal are unnecessary
    /// for choosing the next operation and never enter this projection.
    public struct Dispatch: Encodable, Sendable {
        public let type: String
        public let description: String
        public let result: TaskSteeringState.Result
        public let belongsToCurrentTask: Bool
    }

    public struct UIEvidence: Encodable, Sendable {
        public let unavailable: Bool
        public let captureIncomplete: Bool
        public let omittedElementCount: Int
        public let redactedElementCount: Int
        public let elements: [Element]

        fileprivate init(_ snapshot: AccessibilitySnapshot) {
            unavailable = snapshot.unavailableReason != nil
            captureIncomplete = snapshot.truncated || !snapshot.truncationReasons.isEmpty
                || snapshot.elements.contains(where: \.childrenTruncated)
            redactedElementCount = snapshot.elements.filter(Self.isProtected).count

            // Only unambiguous IDs can identify evidence or supply its ancestor
            // labels. The shared label helper also stops malformed parent cycles.
            let grouped = Dictionary(grouping: snapshot.elements, by: \.id)
            let uniqueElements = grouped.filter { !$0.key.isEmpty }
                .compactMapValues { $0.count == 1 ? $0[0] : nil }
            let labelCounts = Dictionary(grouping: uniqueElements.values.compactMap { Self.nonempty($0.label) },
                                         by: { $0 }).mapValues(\.count)
            let candidates = unavailable ? [] : snapshot.elements.enumerated().compactMap { index, node -> (Int, Int, Element)? in
                guard uniqueElements[node.id] != nil, !Self.isProtected(node),
                      let bounds = node.screenshotBounds, bounds.isValid,
                      bounds.x >= 0, bounds.y >= 0,
                      let evidence = Self.evidence(for: node, elements: uniqueElements,
                                                   repeatedLabel: Self.nonempty(node.label).map { labelCounts[$0, default: 0] > 1 } ?? false)
                else { return nil }
                return (Self.priority(of: node), index, evidence)
            }
            // Landmarks and control state survive a large page of body text.
            // Preserve capture order among equally useful pieces of evidence.
            elements = candidates.sorted {
                $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0
            }.prefix(100).map(\.2)
            // Includes offscreen, protected, redundant, invalid, and capped rows.
            // An absent row must never be interpreted as proof of absence in UI.
            omittedElementCount = snapshot.elements.count - elements.count
        }

        private static let landmarks: Set<String> = ["AXWindow", "AXSheet", "AXDialog", "AXHeading", "AXWebArea"]
        private static let textRoles: Set<String> = ["AXStaticText", "AXText", "AXTitle", "AXHelpTag"]
        private static let containers: Set<String> = [
            "AXApplication", "AXGroup", "AXScrollArea", "AXLayoutArea", "AXLayoutItem",
            "AXSplitGroup", "AXSplitter", "AXToolbar", "AXMenuBar", "AXMenu", "AXList", "AXTable", "AXRow", "AXColumn"
        ]
        private static let nativeActions: Set<String> = ["AXPress", "AXShowMenu", "AXIncrement", "AXDecrement"]

        private static func isProtected(_ node: AccessibilityElement) -> Bool {
            node.secure || node.role.localizedCaseInsensitiveContains("secure")
                || node.subrole?.localizedCaseInsensitiveContains("secure") == true
        }

        private static func evidence(for node: AccessibilityElement, elements: [String: AccessibilityElement],
                                     repeatedLabel: Bool) -> Element? {
            let label = nonempty(node.label)
            let rawValue = nonempty(node.value)
            let value = rawValue == label ? nil : rawValue
            guard label != nil || value != nil else { return nil }
            if containers.contains(node.role), value == nil { return nil }

            let isText = textRoles.contains(node.role) || landmarks.contains(node.role)
            let hasNativeAction = !nativeActions.isDisjoint(with: node.actions)
            // Option labels already carry these names. Keep value-bearing state
            // and disabled controls, plus text/landmarks needed for completion.
            if hasNativeAction, node.enabled == true, value == nil, !isText { return nil }

            // Connect state to the same named section used by native options.
            // Two "Notifications" controls can have different current values.
            let needsContext = value != nil || node.enabled == false || repeatedLabel
            let ancestors = needsContext ? ComputerDecisionOptions.ancestorLabels(for: node, elements: elements) : []
            return Element(role: node.role, label: label, value: value,
                           enabled: !isText && node.enabled == false ? false : nil,
                           within: ancestors.isEmpty ? nil : ancestors)
        }

        private static func priority(of node: AccessibilityElement) -> Int {
            if landmarks.contains(node.role) { return 0 }
            if !textRoles.contains(node.role), nonempty(node.value) != nil || node.enabled == false { return 1 }
            return 2
        }

        private static func nonempty(_ text: String?) -> String? {
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return text
        }
    }

    public struct Element: Encodable, Sendable {
        public let role: String
        public let label: String?
        public let value: String?
        public let enabled: Bool?
        public let within: [String]?
    }
}
