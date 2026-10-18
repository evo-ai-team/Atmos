import Foundation

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
        self.type = type; self.x = x; self.y = y; self.button = button; self.text = text; self.keys = keys; self.scrollX = scrollX; self.scrollY = scrollY; self.path = path
    }
    enum CodingKeys: String, CodingKey { case type, x, y, button, text, keys, path; case scrollX = "scroll_x", scrollY = "scroll_y" }
}
public struct ActionPoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}
public struct ScreenshotFrame: Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var originX: Double
    public var originY: Double
    public var pointWidth: Double
    public var pointHeight: Double
    public var displayID: UInt32
    public init(data: Data, width: Int, height: Int, originX: Double = 0, originY: Double = 0, pointWidth: Double, pointHeight: Double, displayID: UInt32 = 0) {
        self.data = data; self.width = width; self.height = height; self.originX = originX; self.originY = originY; self.pointWidth = pointWidth; self.pointHeight = pointHeight; self.displayID = displayID
    }
    public func screenPoint(x: Double, y: Double) throws -> ActionPoint {
        guard width > 0, height > 0, originX.isFinite, originY.isFinite, pointWidth.isFinite, pointHeight.isFinite, pointWidth > 0, pointHeight > 0, x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(width), y < Double(height) else { throw MouseError.invalidAction("Coordinates are outside the captured display.") }
        return ActionPoint(x: originX + x * pointWidth / Double(width), y: originY + y * pointHeight / Double(height))
    }
    public var dataURL: String { "data:image/jpeg;base64," + data.base64EncodedString() }
}
public struct ComputerCall: Sendable {
    public var callID: String
    public var actions: [ComputerAction]
    public var description: String
    public var safetyChecks: [String]
    public init(callID: String, actions: [ComputerAction], description: String, safetyChecks: [String] = []) {
        self.callID = callID; self.actions = actions; self.description = description; self.safetyChecks = safetyChecks
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
    public var inputTokens: Int
    public var outputTokens: Int
    public init(id: String, calls: [ComputerCall], message: String = "", pauseReason: String? = nil, ignored: Bool = false, inputTokens: Int = 0, outputTokens: Int = 0) {
        self.id = id; self.calls = calls; self.message = message; self.pauseReason = pauseReason; self.ignored = ignored
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
    }
}
public enum MouseError: LocalizedError, Equatable {
    case invalidAction(String), permission(String), api(String), configuration(String), limit(String)
    public var errorDescription: String? {
        switch self { case .invalidAction(let s), .permission(let s), .api(let s), .configuration(let s), .limit(let s): return s }
    }
}
