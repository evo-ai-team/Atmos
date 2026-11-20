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
public struct AtmosPreferences: Equatable, Sendable {
    public var behavior: ChatbotBehavior
    public var audioSensitivity: Double
    public var vivaProEnabled: Bool
    public var microphoneMuted: Bool
    public var secondPassEnabled: Bool
    public var displayTapsEnabled: Bool
    public var displayTapThreshold: Double
    public var displayTapProfile: DisplayTapProfile?

    public init(behavior: ChatbotBehavior = .decisionsTextOnly,
                audioSensitivity: Double = 0.5, secondPassEnabled: Bool = true, vivaProEnabled: Bool = false,
                displayTapsEnabled: Bool = true, displayTapThreshold: Double? = nil,
                displayTapProfile: DisplayTapProfile? = nil, microphoneMuted: Bool = false) {
        self.behavior = behavior
        self.audioSensitivity = Self.validSensitivity(audioSensitivity)
        self.vivaProEnabled = vivaProEnabled
        self.microphoneMuted = microphoneMuted
        self.secondPassEnabled = secondPassEnabled
        self.displayTapsEnabled = displayTapsEnabled
        self.displayTapProfile = displayTapProfile.flatMap { $0.isValid ? $0 : nil }
        self.displayTapThreshold = Self.validTapThreshold(displayTapThreshold ?? self.displayTapProfile?.threshold
                                                          ?? DisplayTapRecognizer.defaultThreshold)
    }

    public static func load(from defaults: UserDefaults = .standard) -> Self {
        let profile = defaults.data(forKey: "atmos.displayTapProfile").flatMap {
            try? JSONDecoder().decode(DisplayTapProfile.self, from: $0)
        }
        return Self(
            behavior: defaults.string(forKey: "atmos.chatbotBehavior").flatMap(ChatbotBehavior.init(rawValue:)) ?? .decisionsTextOnly,
            audioSensitivity: (defaults.object(forKey: "atmos.audioSensitivity") as? NSNumber)?.doubleValue ?? 0.5,
            secondPassEnabled: (defaults.object(forKey: "atmos.secondPassEnabled") as? NSNumber)?.boolValue ?? true,
            vivaProEnabled: defaults.bool(forKey: "atmos.vivaProEnabled"),
            displayTapsEnabled: (defaults.object(forKey: "atmos.displayTapsEnabled") as? NSNumber)?.boolValue ?? true,
            displayTapThreshold: (defaults.object(forKey: "atmos.displayTapThreshold") as? NSNumber)?.doubleValue,
            displayTapProfile: profile,
            microphoneMuted: defaults.bool(forKey: "atmos.microphoneMuted")
        )
    }

    public func save(to defaults: UserDefaults = .standard) {
        defaults.set(behavior.rawValue, forKey: "atmos.chatbotBehavior")
        defaults.set(Self.validSensitivity(audioSensitivity), forKey: "atmos.audioSensitivity")
        defaults.set(vivaProEnabled, forKey: "atmos.vivaProEnabled")
        defaults.set(microphoneMuted, forKey: "atmos.microphoneMuted")
        defaults.set(secondPassEnabled, forKey: "atmos.secondPassEnabled")
        defaults.set(displayTapsEnabled, forKey: "atmos.displayTapsEnabled")
        defaults.set(Self.validTapThreshold(displayTapThreshold), forKey: "atmos.displayTapThreshold")
        if let displayTapProfile, displayTapProfile.isValid, let data = try? JSONEncoder().encode(displayTapProfile) {
            defaults.set(data, forKey: "atmos.displayTapProfile")
        } else {
            defaults.removeObject(forKey: "atmos.displayTapProfile")
        }
    }

    private static func validSensitivity(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0.5
    }

    public static let displayTapThresholdRange = DisplayTapProfile.thresholdRange

    private static func validTapThreshold(_ value: Double) -> Double {
        guard value.isFinite else { return DisplayTapRecognizer.defaultThreshold }
        return max(displayTapThresholdRange.lowerBound, min(displayTapThresholdRange.upperBound, value))
    }
}
