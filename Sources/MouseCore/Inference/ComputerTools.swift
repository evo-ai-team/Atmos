/// Closed tool schemas advertised to the planner. ComputerResponseParser separately
/// validates returned values before any action can reach the native executor.
enum ComputerTools {
    /// Each action is a closed, discriminated object. Keeping unrelated fields out of each
    /// variant avoids large null-filled payloads and catches mismatched actions before input.
    static let definitions: [[String: Any]] = {
        let coordinate: [String: Any] = ["type": "number", "minimum": 0]
        let modifiers: [String: Any] = ["type": "array", "items": ["type": "string", "enum": ["CMD", "CTRL", "ALT", "SHIFT"]], "maxItems": 4]
        func object(_ properties: [String: Any]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": properties.keys.sorted(), "additionalProperties": false]
        }
        func action(_ type: String, _ fields: [String: Any] = [:]) -> [String: Any] {
            var properties = fields
            properties["type"] = ["type": "string", "enum": [type]]
            return object(properties)
        }
        let pointer: [String: Any] = ["x": coordinate, "y": coordinate, "keys": modifiers]
        var click = pointer
        click["button"] = ["type": "string", "enum": ["left", "right", "middle", "back", "forward"]]
        var scroll = pointer
        scroll["scroll_x"] = ["type": "number", "minimum": -100_000, "maximum": 100_000]
        scroll["scroll_y"] = scroll["scroll_x"]
        let variants = [
            action("click", click), action("double_click", click), action("move", pointer), action("scroll", scroll),
            action("drag", ["path": ["type": "array", "minItems": 2, "maxItems": 100, "items": object(["x": coordinate, "y": coordinate])], "keys": modifiers]),
            action("type", ["text": ["type": "string", "minLength": 1, "maxLength": 10_000]]),
            action("keypress", ["keys": ["type": "array", "minItems": 1, "maxItems": 5, "items": ["type": "string", "minLength": 1, "maxLength": 24]]]),
            action("wait"), action("screenshot")
        ]
        let taskUpdate = object([
            "kind": ["type": "string", "enum": ["revise", "replace"], "description": "Revise the active task, or replace it for a new task. No active task means replace."],
            "goal": ["type": "string", "minLength": 1, "maxLength": 2_000, "description": "The complete current goal, including any new amendment and preserving unaffected requirements when revising."]
        ])
        return [
            ["type": "function", "name": "execute_actions", "strict": true,
             "description": "Perform one short, screenshot-grounded UI operation with its brief in-progress description. The result is a fresh screenshot.",
             "parameters": object([
                "task_update": taskUpdate,
                "description": ["type": "string", "minLength": 1, "maxLength": 40, "description": "A 1–2-word in-progress label without an ellipsis: Loading Store, Opening YouTube, Clicking Channel. Describe only this batch, never completion."],
                "actions": ["type": "array", "minItems": 1, "maxItems": 12, "items": ["anyOf": variants]]
             ])],
            ["type": "function", "name": "pause_for_user", "strict": true,
             "description": "For a clear computer-control request only: stop when its target, information, authorization, authentication, or user review is needed. Unclear action intent must use ignore_utterance.",
             "parameters": object([
                "task_update": taskUpdate,
                "reason": ["type": "string", "minLength": 1, "maxLength": 180, "description": "A concise question or explanation of what the user needs to provide."]
             ])],
            ["type": "function", "name": "ignore_utterance", "strict": true,
             "description": "Silently ignore background conversation or speech that neither clearly requests computer control nor asks Mouse a question. Quoted, hypothetical, or negated actions do not authorize input. No action or reply.",
             "parameters": object([:])],
            ["type": "function", "name": "answer_question", "strict": true,
             "description": "Answer a current question clearly addressed to Mouse, including general, how-to, screen, or task-context questions. Text only; never dispatch input, revise an accepted task, or report task completion.",
             "parameters": object([
                "text": ["type": "string", "minLength": 1, "maxLength": 4_000, "description": "The concise text answer. Multiple lines are allowed; distinguish observed facts from uncertainty."]
             ])],
            ["type": "function", "name": "complete_task", "strict": true,
             "description": "Complete immediately when the current screenshot shows the entire goal is satisfied and actual dispatched history is consistent with that result. Preserve the full current goal; do not add another action or observation.",
             "parameters": object([
                "task_update": taskUpdate,
                "message": ["type": "string", "minLength": 1, "maxLength": 180, "description": "A concise completion message for the verified current goal."]
             ])]
        ]
    }()
}
