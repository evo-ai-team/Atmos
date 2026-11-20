import Foundation

/// Before considering a network-delayed endpoint, classify the microphone
/// samples already captured when the cleaned stream first appeared quiet.
public struct IsolatedSpeechEndpoint {
    private var fence: TimeInterval?
    private var observedActivity: TimeInterval?

    public init() {}

    public mutating func ready(cleanThrough: TimeInterval, capturedThrough: TimeInterval,
                               lastActivity: TimeInterval, silence: TimeInterval) -> Bool {
        if observedActivity != lastActivity {
            observedActivity = lastActivity
            fence = nil
        }
        guard cleanThrough - lastActivity >= silence else { return false }
        if fence == nil { fence = capturedThrough }
        return cleanThrough >= (fence ?? capturedThrough)
    }
}
