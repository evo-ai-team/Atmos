import Foundation

/// A plain-data view of one accessibility capture. Native AX handles never leave
/// the controller, and element IDs only mean something inside this snapshot.
public struct AccessibilitySnapshot: Codable, Sendable {
    public var id: UUID
    public var processID: Int32
    public var capturedAt: TimeInterval
    public var elements: [AccessibilityElement]
    public var truncated: Bool
    public var rootIDs: [String]
    public var truncationReasons: [String]
    public var unavailableReason: String?

    public init(id: UUID = UUID(), processID: Int32, capturedAt: TimeInterval = Date().timeIntervalSince1970,
                elements: [AccessibilityElement], truncated: Bool = false, rootIDs: [String] = [],
                truncationReasons: [String] = [], unavailableReason: String? = nil) {
        self.id = id
        self.processID = processID
        self.capturedAt = capturedAt
        self.elements = elements
        self.truncated = truncated
        self.rootIDs = rootIDs
        self.truncationReasons = truncationReasons
        self.unavailableReason = unavailableReason
    }

    /// Keep failures explicit: an unavailable tree must never look like evidence
    /// that an app has no buttons or content.
    public var contextText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else {
            return "{\"unavailableReason\":\"Accessibility snapshot could not be encoded\"}"
        }
        return text
    }
}

public struct AccessibilityElement: Codable, Equatable, Sendable {
    public var id: String
    public var parentID: String?
    public var childIDs: [String]
    public var role: String
    public var subrole: String?
    public var label: String?
    public var value: String?
    public var help: String?
    /// Nil means the application did not expose an enabled state.
    public var enabled: Bool?
    public var actions: [String]
    public var screenBounds: AccessibilityBounds?
    public var screenshotBounds: AccessibilityBounds?
    public var secure: Bool
    public var childCount: Int?
    public var childrenTruncated: Bool

    public init(id: String, parentID: String? = nil, childIDs: [String] = [], role: String,
                subrole: String? = nil, label: String? = nil, value: String? = nil, help: String? = nil,
                enabled: Bool? = nil, actions: [String] = [], screenBounds: AccessibilityBounds? = nil,
                screenshotBounds: AccessibilityBounds? = nil, secure: Bool = false,
                childCount: Int? = nil, childrenTruncated: Bool = false) {
        self.id = id
        self.parentID = parentID
        self.childIDs = childIDs
        self.role = role
        self.subrole = subrole
        self.secure = secure
        // A second boundary prevents accidental serialization if a future caller
        // supplies text for a protected field. The native reader skips it entirely.
        self.label = secure ? "Secure text field" : label
        self.value = secure ? nil : value
        self.help = secure ? nil : help
        self.enabled = enabled
        self.actions = secure ? [] : actions
        self.screenBounds = screenBounds
        self.screenshotBounds = screenshotBounds
        self.childCount = childCount
        self.childrenTruncated = childrenTruncated
    }
}

/// Screen bounds use Quartz global points (top-left origin), not AppKit's
/// bottom-left coordinates. Screenshot bounds use the actual encoded pixels.
public struct AccessibilityBounds: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var isValid: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0
            && (x + width).isFinite && (y + height).isFinite
    }

    /// Clip to the captured display before mapping. A tree can include offscreen
    /// controls; nil means there is no visible rectangle in this screenshot, not
    /// that the control lacks an accessibility action.
    public func screenshotBounds(in frame: ScreenshotFrame) -> AccessibilityBounds? {
        guard isValid, frame.width > 0, frame.height > 0,
              frame.originX.isFinite, frame.originY.isFinite,
              frame.pointWidth.isFinite, frame.pointHeight.isFinite,
              frame.pointWidth > 0, frame.pointHeight > 0 else { return nil }
        let left = max(x, frame.originX), top = max(y, frame.originY)
        let right = min(x + width, frame.originX + frame.pointWidth)
        let bottom = min(y + height, frame.originY + frame.pointHeight)
        guard right > left, bottom > top else { return nil }
        let scaleX = Double(frame.width) / frame.pointWidth
        let scaleY = Double(frame.height) / frame.pointHeight
        return AccessibilityBounds(x: (left - frame.originX) * scaleX,
                                   y: (top - frame.originY) * scaleY,
                                   width: (right - left) * scaleX,
                                   height: (bottom - top) * scaleY)
    }
}
