import Foundation

/// Wire-format action data. Optional fields mirror the model protocol; parsing
/// and native preflight must validate the selected action before dispatch.
public struct ComputerAction: Codable, Equatable, Sendable {
    public var type: String
    public var x: Double?
    public var y: Double?
    public var button: String?
    public var text: String?
    public var keys: [String]?
    public var scrollX: Double?
    public var scrollY: Double?
    public var path: [ActionPoint]?
    public init(type: String, x: Double? = nil, y: Double? = nil, button: String? = nil, text: String? = nil, keys: [String]? = nil, scrollX: Double? = nil, scrollY: Double? = nil, path: [ActionPoint]? = nil) {
        self.type = type
        self.x = x
        self.y = y
        self.button = button
        self.text = text
        self.keys = keys
        self.scrollX = scrollX
        self.scrollY = scrollY
        self.path = path
    }
    enum CodingKeys: String, CodingKey { case type, x, y, button, text, keys, path; case scrollX = "scroll_x", scrollY = "scroll_y" }
}
public struct ActionPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct ComputerCall: Sendable {
    public var callID: String
    public var actions: [ComputerAction]
    public var description: String
    public init(callID: String, actions: [ComputerAction], description: String) {
        self.callID = callID
        self.actions = actions
        self.description = description
    }
}
/// The generative planner resolves an amendment and returns the complete updated
/// goal alongside its next action or pause, preserving unaffected requirements.
public struct TaskUpdate: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case revise, replace
    }
    public var kind: Kind
    public var goal: String
    public init(kind: Kind, goal: String) {
        self.kind = kind
        self.goal = goal
    }
}
public struct ModelTurn: Sendable {
    public var id: String
    public var calls: [ComputerCall]
    public var message: String
    /// A request for user input or review; never accompanied by executable actions.
    public var pauseReason: String?
    /// The utterance was not a clear request for computer control. Stay silent and take no action.
    public var ignored: Bool
    /// Present with an action, pause, or complete_task; absent only for ignored speech.
    public var taskUpdate: TaskUpdate?
    public var inputTokens: Int
    public var outputTokens: Int
    public init(id: String, calls: [ComputerCall], message: String = "", pauseReason: String? = nil, ignored: Bool = false, taskUpdate: TaskUpdate? = nil, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.id = id
        self.calls = calls
        self.message = message
        self.pauseReason = pauseReason
        self.ignored = ignored
        self.taskUpdate = taskUpdate
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}
public enum MouseError: LocalizedError, Equatable {
    case invalidAction(String), permission(String), api(String), configuration(String)
    public var errorDescription: String? {
        switch self { case .invalidAction(let s), .permission(let s), .api(let s), .configuration(let s): return s }
    }
}
