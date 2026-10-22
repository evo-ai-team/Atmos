import Foundation

/// The first model both accepts the command and chooses its next action.
/// Raw values are persisted, so changing a display title does not reset a choice.
public enum ChatbotBehavior: String, CaseIterable, Codable, Sendable {
    case luna
    case decisionsWithImage
    case decisionsTextOnly

    public var title: String {
        switch self {
        case .luna: return "Luna only"
        case .decisionsWithImage: return "Decisions + screenshot"
        case .decisionsTextOnly: return "Decisions · text only"
        }
    }

    public var detail: String {
        switch self {
        case .luna: return "Luna sees the screen and acts or ignores the command."
        case .decisionsWithImage: return "Decisions sees the screen and selects an action. Luna handles fallback."
        case .decisionsTextOnly: return "Decisions uses accessibility text. Luna sees the screen only for fallback."
        }
    }

    public var usesDecisions: Bool { self != .luna }
    public var decisionsUseScreenshot: Bool { self == .decisionsWithImage }
}

/// Small local preferences, separate from credentials and session history.
/// Missing keys preserve the behavior of existing installations.
public struct MousePreferences: Equatable, Sendable {
    public var behavior: ChatbotBehavior
    public var audioSensitivity: Double
    public var secondPassEnabled: Bool

    public init(behavior: ChatbotBehavior = .decisionsTextOnly,
                audioSensitivity: Double = 0.5, secondPassEnabled: Bool = true) {
        self.behavior = behavior
        self.audioSensitivity = Self.validSensitivity(audioSensitivity)
        self.secondPassEnabled = secondPassEnabled
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        Self(
            behavior: defaults.string(forKey: "mouse.chatbotBehavior").flatMap(ChatbotBehavior.init(rawValue:)) ?? .decisionsTextOnly,
            audioSensitivity: (defaults.object(forKey: "mouse.audioSensitivity") as? NSNumber)?.doubleValue ?? 0.5,
            secondPassEnabled: (defaults.object(forKey: "mouse.secondPassEnabled") as? NSNumber)?.boolValue ?? true
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(behavior.rawValue, forKey: "mouse.chatbotBehavior")
        defaults.set(Self.validSensitivity(audioSensitivity), forKey: "mouse.audioSensitivity")
        defaults.set(secondPassEnabled, forKey: "mouse.secondPassEnabled")
    }

    private static func validSensitivity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }
}
