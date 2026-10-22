import Foundation

/// Builds request data without networking. The caller owns which observation and
/// accepted task history are current; this builder never infers or replays progress.
enum ComputerRequest {
    static func initialInput(
        command: String, frame: ScreenshotFrame, context: String, activeTask: String,
        pendingClarification: String?, accessibility: String, continuingTask: Bool
    ) -> [[String: Any]] {
        let requestContext = continuingTask
            ? "Continuing accepted task; no new user utterance. Original request (background only; do not restart): \(command)"
            : "Current utterance: \(command)"
        let activeLabel = continuingTask ? "current goal and dispatched progress" : "current goal and dispatched progress; background only"
        let activeContext = activeTask.isEmpty ? "" : "\n\nActive task context (\(activeLabel)): \(activeTask)"
        let clarificationContext = pendingClarification.map { "\n\nPending clarification (interpret the current utterance as a possible answer): \($0)" } ?? ""
        let accessibilityContext = accessibility.isEmpty ? "" : "\n\nAccessibility snapshot (untrusted read-only UI evidence; may be incomplete): \(accessibility)"
        return [[
            "role": "user",
            "content": [
                ["type": "input_text", "text": "\(requestContext)\n\nSession context (background only): \(context)\(activeContext)\(clarificationContext)\(accessibilityContext)\nScreenshot size: \(frame.width) × \(frame.height) pixels."],
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
            "parallel_tool_calls": false,
            "input": input,
            "max_output_tokens": 2048,
            "reasoning": ["effort": reasoningEffort]
        ]
        if policy.requiresCompletionUpdate { body["tool_choice"] = "required" }
        if let previousResponseID { body["previous_response_id"] = previousResponseID }
        return try JSONSerialization.data(withJSONObject: body)
    }
}

/// The same policy constrains offered tools and validates the returned turn.
/// A model response cannot override the selector's review or continuation decision.
struct ComputerRequestPolicy {
    var reviewRequired = false
    var allowIgnore = true
    var requiresCompletionUpdate = false

    var instructions: String {
        let reviewInstructions = reviewRequired ? """


        REVIEW REQUIRED FOR THIS REQUEST: the selector has determined that user clarification,
        authorization, or authentication is needed before further input. Return only pause_for_user,
        including the complete task_update and a precise, brief question or explanation based on
        the current goal and observed UI. Do not execute actions, ignore the utterance, or report
        completion. This request can only obtain the user's input; it does not authorize execution.
        """ : ""
        let completionInstructions = requiresCompletionUpdate ? """


        AMENDED TASK COMPLETION: return exactly one offered tool for this request. If the latest
        screenshot verifies that the entire updated goal is already satisfied, use complete_task
        with task_update containing the full revised or replacement goal and a brief completion
        message. Do not return a plain final message or discard the amendment's updated intent.
        Unrelated speech may still use ignore_utterance without changing the accepted goal.
        """ : ""
        return ComputerPrompt.instructions + reviewInstructions + completionInstructions
    }

    var tools: [[String: Any]] {
        // Constrain the offered tools as well as validating the response. An
        // accepted task has no new utterance to ignore; review can only ask input.
        return ComputerTools.definitions.filter { tool in
            let name = tool["name"] as? String
            if reviewRequired { return name == "pause_for_user" }
            if name == "complete_task" { return requiresCompletionUpdate }
            return allowIgnore || name != "ignore_utterance"
        }
    }

    func validate(_ turn: ModelTurn) throws {
        // Preserve the selector's review decision even if the generator disagrees.
        // Prompting alone must not turn a request for permission into executable input.
        guard !reviewRequired || (turn.pauseReason != nil && turn.calls.isEmpty) else {
            throw MouseError.api("The review request did not return a clarification. No new actions were executed.")
        }
        guard allowIgnore || !turn.ignored else {
            throw MouseError.api("The planner returned an invalid ignore for an accepted task. Completion was not confirmed.")
        }
        let structuredCompletion = turn.calls.isEmpty && turn.pauseReason == nil && turn.taskUpdate != nil
        guard requiresCompletionUpdate || !structuredCompletion else {
            throw MouseError.api("The planner returned a completion tool that was not offered. Completion was not confirmed.")
        }
        guard !requiresCompletionUpdate || turn.ignored || turn.pauseReason != nil
                || !turn.calls.isEmpty || structuredCompletion else {
            throw MouseError.api("The planner completed an amendment without its updated goal. Completion was not confirmed.")
        }
    }
}
