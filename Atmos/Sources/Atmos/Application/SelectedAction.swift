import Foundation
#if SWIFT_PACKAGE
import AtmosCore
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
    init(lunaTurn: ModelTurn, tree: AccessibilitySnapshot, fallbackFrom: SelectedAction? = nil) throws {
        let outcome: String
        let native = lunaTurn.calls.flatMap(\.actions).first { $0.type == "accessibility" }
        if let native {
            guard lunaTurn.calls.count == 1, lunaTurn.calls[0].actions.count == 1,
                  let request = native.accessibility else {
                throw AtmosError.invalidAction("An accessibility turn must contain exactly one native action.")
            }
            let element = try request.resolve(in: tree)
            operation = .native(element, action: request.action, description: lunaTurn.calls[0].description)
            outcome = "Accessibility action"
        } else if let id = lunaTurn.showAnswerID {
            operation = .showAnswer(id)
            outcome = "Open answer"
        } else if lunaTurn.answer != nil {
            operation = .generate
            outcome = "Answer"
        } else if lunaTurn.ignored {
            operation = .ignore
            outcome = "Ignore"
        } else if lunaTurn.pauseReason != nil {
            operation = .review
            outcome = "Clarification"
        } else if lunaTurn.calls.isEmpty {
            operation = .complete
            outcome = "Complete"
        } else {
            operation = .generate
            outcome = "Action"
        }
        nativeRelationship = nil
        route = (fallbackFrom?.route ?? "Luna Responses") + (native == nil ? "" : " → accessibility")
        choiceSummary = "Screenshot + command · \(tree.elements.count) accessibility elements"
        decisionSummary = (fallbackFrom.map { $0.decisionSummary + "\n" } ?? "") + "Luna → \(outcome)\n\(choiceSummary)"
        offeredTargets = fallbackFrom?.offeredTargets ?? []
        treeSummary = fallbackFrom?.treeSummary ?? decisionSummary
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
        case .showAnswer: route = "Open answer"
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
        case .showAnswer(let id):
            return ModelTurn(id: UUID().uuidString, calls: [], showAnswerID: id)
        case .generate, .review:
            return nil
        }
    }
}
