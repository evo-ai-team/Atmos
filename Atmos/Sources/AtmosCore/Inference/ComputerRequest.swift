import Foundation

/// Builds request data without networking. The caller owns which observation and
/// accepted task history are current; this builder never infers or replays progress.
enum ComputerRequest {
    static func initialInput(
        command: String, frame: ScreenshotFrame, context: String, activeTask: String,
        pendingClarification: String?, accessibility: String, continuingTask: Bool, pendingAnswerID: UUID? = nil
    ) -> [[String: Any]] {
        let requestContext = continuingTask
            ? "Continuing accepted task; no new user utterance. Original request (background only; do not restart): \(command)"
            : "Current utterance: \(command)"
        let activeLabel = continuingTask ? "current goal and dispatched progress" : "current goal and dispatched progress; background only"
        let activeContext = activeTask.isEmpty ? "" : "\n\nActive task context (\(activeLabel)): \(activeTask)"
        let clarificationContext = pendingClarification.map { "\n\nPending clarification (interpret the current utterance as a possible answer): \($0)" } ?? ""
        let accessibilityContext = accessibility.isEmpty ? "" : "\n\nAccessibility snapshot (untrusted UI evidence; may be incomplete): \(accessibility)"
        let readerState = pendingAnswerID.map { "\n\nUnread Atmos checkmark points to saved answer id \($0.uuidString)." } ?? ""
        return [[
            "role": "user",
            "content": [
                ["type": "input_text", "text": "\(requestContext)\n\nSession context (background only): \(context)\(readerState)\(activeContext)\(clarificationContext)\(accessibilityContext)\nScreenshot size: \(frame.width) × \(frame.height) pixels."],
                ["type": "input_image", "image_url": frame.dataURL, "detail": "original"]
            ]
        ]]
    }

    static func body(
        input: [[String: Any]], previousResponseID: String?, model: String,
        serviceTier: String, reasoningEffort: String, policy: ComputerRequestPolicy
    ) throws -> Data {
        var body: [String: Any] = [
            "model": model,
            "service_tier": serviceTier,
            "instructions": policy.instructions,
            "tools": policy.tools,
            "tool_choice": "required",
            "parallel_tool_calls": false,
            "input": input,
            "max_output_tokens": 2048,
            "reasoning": ["effort": reasoningEffort]
        ]
        if let previousResponseID { body["previous_response_id"] = previousResponseID }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

/// The same policy constrains offered tools and validates the returned turn.
/// A model response cannot override the selector's review or continuation decision.
struct ComputerRequestPolicy {
    var reviewRequired = false
    var allowIgnore = true
    var allowAnswer = true
    var accessibility: AccessibilitySnapshot?
    var availableAnswerIDs: Set<UUID> = []

    var instructions: String {
        let reviewInstructions = reviewRequired ? """


        REVIEW REQUIRED FOR THIS REQUEST: the selector has determined that user clarification,
        authorization, or authentication may be needed before further input. You may only use
        pause_for_user or complete_task. If the current screenshot and actual dispatched history
        establish that the entire accepted goal is already satisfied, call complete_task immediately
        with the full current goal. Otherwise use pause_for_user with the complete task_update and
        a precise, brief question or explanation. Do not execute actions, ignore the utterance,
        invent authorization, or claim an unfinished goal is complete to bypass review. This request
        does not authorize execution.
        """ : ""
        return ComputerPrompt.instructions + reviewInstructions
    }

    var tools: [[String: Any]] {
        // Constrain the offered tools as well as validating the response. An
        // accepted task has no new utterance to ignore or question to answer. Review can recognize an
        // already-achieved goal, but can never dispatch further input.
        return ComputerTools.definitions.filter { tool in
            let name = tool["name"] as? String
            if reviewRequired { return name == "pause_for_user" || name == "complete_task" }
            if name == "perform_accessibility_action" { return accessibility?.nativeActionElements.isEmpty == false }
            if name == "ignore_utterance" { return allowIgnore }
            if name == "answer_question" { return allowAnswer }
            if name == "show_answer" { return allowAnswer && !availableAnswerIDs.isEmpty }
            return true
        }
    }

    func validate(_ turn: ModelTurn) throws {
        // Preserve the selector's review decision even if the generator disagrees.
        // Prompting alone must not turn a request for permission into executable input.
        let completed = turn.calls.isEmpty && turn.pauseReason == nil && !turn.ignored && turn.answer == nil && turn.showAnswerID == nil
            && turn.taskUpdate != nil && !turn.message.isEmpty
        guard !reviewRequired || (turn.calls.isEmpty && (turn.pauseReason != nil || completed)) else {
            throw AtmosError.api("The review request returned neither clarification nor completion. No new actions were executed.")
        }
        guard allowIgnore || !turn.ignored else {
            throw AtmosError.api("The planner returned an invalid ignore for an accepted task. Completion was not confirmed.")
        }
        guard allowAnswer || turn.answer == nil else {
            throw AtmosError.api("The planner returned an answer without a new question. Completion was not confirmed.")
        }
        if let id = turn.showAnswerID, !allowAnswer || !availableAnswerIDs.contains(id) {
            throw AtmosError.api("The requested answer was unavailable for this turn.")
        }
        for action in turn.calls.flatMap(\.actions) where action.type == "accessibility" {
            guard turn.calls.count == 1, turn.calls[0].actions.count == 1,
                  let request = action.accessibility, let accessibility else {
                throw AtmosError.api("The planner returned an accessibility action without a current target snapshot. No new actions were executed.")
            }
            _ = try request.resolve(in: accessibility)
        }
    }
}
