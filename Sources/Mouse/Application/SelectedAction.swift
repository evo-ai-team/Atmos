import Foundation
#if SWIFT_PACKAGE
import MouseCore
#endif

/// A selection and its diagnostics belong to one observation. This describes an
/// intended operation; only the dispatcher can report whether input was sent.
struct SelectedAction {
    struct NativeTarget {
        let element: AccessibilityElement
        let action: String
    }

    let operation: ComputerDecision
    let nativeRelationship: TaskUpdate.Kind?
    let route: String
    let choiceSummary: String
    let decisionSummary: String
    let offeredTargets: [DecisionChoice]
    let treeSummary: String
    var accessibilityController: AccessibilityController?

    /// Responses-only mode produces its own action/ignore/completion in one call.
    /// It never creates an artificial Decisions result to enter the dispatcher.
    init(lunaTurn: ModelTurn, tree: AccessibilitySnapshot) {
        operation = lunaTurn.ignored ? .ignore : lunaTurn.pauseReason != nil ? .review
            : lunaTurn.calls.isEmpty ? .complete : .generate
        nativeRelationship = nil
        route = "Luna Responses"
        choiceSummary = "Screenshot + command · \(tree.elements.count) accessibility elements"
        decisionSummary = "Luna → \(lunaTurn.ignored ? "Ignore" : lunaTurn.pauseReason != nil ? "Clarification" : lunaTurn.calls.isEmpty ? "Complete" : "Action")\n\(choiceSummary)"
        offeredTargets = []
        treeSummary = decisionSummary
    }

    init(result: DecisionResult, options: ComputerDecisionOptions, tree: AccessibilitySnapshot) throws {
        let selection = try options.resolveSelection(result)
        operation = selection.operation
        switch operation {
        case .native: route = "Native accessibility"
        case .generate: route = "Responses fallback"
        case .review: route = "Responses clarification"
        case .complete: route = "Complete"
        case .ignore: route = "Ignore"
        }

        // Native selection cannot rewrite a goal. Preserve the accepted words and
        // their relationship locally instead of forcing another model request.
        switch operation {
        case .native, .complete:
            switch selection.taskRelationship {
            case .revise: nativeRelationship = .revise
            case .replace: nativeRelationship = .replace
            default: nativeRelationship = nil
            }
        default: nativeRelationship = nil
        }

        // The model sees short menu IDs. Native identity stays in the local map,
        // so diagnostics must not infer action types by parsing choice strings.
        let pressCount = options.nativeActionCount("AXPress")
        let menuCount = options.nativeActionCount("AXShowMenu")
        let availability = tree.unavailableReason != nil ? " · tree unavailable"
            : tree.truncated ? " · partial tree" : ""
        choiceSummary = "\(options.nativeOptionCount) native choices · \(tree.elements.count) elements\(availability)"
            + " · \(pressCount) press / \(menuCount) context menu"
        decisionSummary = "Decisions → \(route)\n\(choiceSummary)"
            + (selection.taskRelationship.map { "\nTask relationship: \($0.rawValue)" } ?? "")
        offeredTargets = options.nativeOptions
        treeSummary = decisionSummary
            + (tree.truncationReasons.isEmpty ? "" : "\nCapture limits: " + tree.truncationReasons.joined(separator: ", "))
            + (tree.unavailableReason.map { "\n" + $0 } ?? "")
    }

    var nativeTarget: NativeTarget? {
        guard case let .native(element, action, _) = operation else { return nil }
        return NativeTarget(element: element, action: action)
    }

    /// Only free-form generation and clarification need a Responses request.
    var immediateTurn: ModelTurn? {
        switch operation {
        case let .native(element, action, description):
            // This record describes dispatch intent, not a reusable AX handle.
            let action = ComputerAction(type: "accessibility", text: "\(action) on \(element.label ?? element.role)")
            let call = ComputerCall(callID: UUID().uuidString, actions: [action], description: description)
            return ModelTurn(id: UUID().uuidString, calls: [call])
        case .complete:
            return ModelTurn(id: UUID().uuidString, calls: [], message: "Done")
        case .ignore:
            return ModelTurn(id: UUID().uuidString, calls: [], ignored: true)
        case .generate, .review:
            return nil
        }
    }
}
