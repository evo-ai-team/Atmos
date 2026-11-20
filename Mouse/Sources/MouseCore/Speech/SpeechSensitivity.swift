import Foundation

/// Controls speech-activity detection, not microphone gain or recognizer audio.
/// Higher sensitivity lets quieter sound keep an utterance open.
public enum SpeechSensitivity {
    public static let defaultValue = 0.5

    public static func normalized(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : defaultValue
    }

    /// An exponential slider gives equal movement an equal relative change in
    /// amplitude. The midpoint retains Mouse's original RMS threshold exactly;
    /// either end changes it by a factor of four without allowing a zero gate.
    public static func energyThreshold(for value: Double) -> Double {
        0.006 * pow(4, 1 - 2 * normalized(value))
    }
}
