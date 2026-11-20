import Foundation
import simd

/// Detects short, settled chassis vibrations from timestamped accelerometer
/// reports in g. Only the first tap's deadline can emit a single-tap action.
public struct DisplayTapRecognizer {
    public enum Event: Equatable, Sendable {
        case firstTapPending
        case singleTap
        case doubleTap
    }

    public static let defaultThreshold = 0.015
    public static let doubleTapInterval: TimeInterval = 0.300
    public let threshold: Double
    private let profile: DisplayTapProfile?
    /// Distance from the local rest vector in g, for sensitivity calibration.
    public private(set) var signalLevel = 0.0

    private struct Pulse {
        let start: TimeInterval
        let threshold: Double
        var peak: Double
        var quietSince: TimeInterval?
    }

    private var refractory: TimeInterval { profile?.ringingInterval ?? 0.115 }
    private var maxPulseDuration: TimeInterval { profile.map { max(0.115, $0.ringingInterval + 0.025) } ?? 0.115 }
    private var pairWindow: TimeInterval { profile?.doubleTapInterval ?? Self.doubleTapInterval }
    private var rest: SIMD3<Double>?
    private var previous = SIMD3<Double>.zero
    private var lastSampleAt: TimeInterval?
    private var quietSince: TimeInterval?
    private var lastArmedAt: TimeInterval?
    private var blockedUntil: TimeInterval = 0
    private var noise = 0.0
    private var pulse: Pulse?
    private var firstTapAt: TimeInterval?

    public init(threshold: Double = Self.defaultThreshold) {
        profile = nil
        self.threshold = threshold.isFinite && threshold > 0 ? threshold : Self.defaultThreshold
    }

    public init(profile: DisplayTapProfile, thresholdOverride: Double? = nil) {
        self.profile = profile.isValid ? profile : nil
        let fittedThreshold = self.profile?.threshold ?? Self.defaultThreshold
        if let thresholdOverride, thresholdOverride.isFinite, thresholdOverride > 0 {
            threshold = thresholdOverride
        } else {
            threshold = fittedThreshold
        }
    }

    public var pendingDeadline: TimeInterval? {
        guard let firstTapAt else { return nil }
        let deadline = firstTapAt + pairWindow
        if let pulse, pulse.start <= deadline {
            return max(deadline, pulse.start + maxPulseDuration)
        }
        return deadline
    }

    public mutating func reset() {
        if let profile { self = Self(profile: profile, thresholdOverride: threshold) }
        else { self = Self(threshold: threshold) }
    }

    /// A timer may check a pending gesture, but only sensor time proves the
    /// double-tap window was quiet. This preserves paired taps in batched reports.
    public mutating func advance(to time: TimeInterval) -> [Event] {
        guard time.isFinite, let lastSampleAt, let deadline = pendingDeadline,
              min(time, lastSampleAt) >= deadline else { return [] }
        firstTapAt = nil
        return [.singleTap]
    }

    public mutating func sample(x: Double, y: Double, z: Double, at time: TimeInterval,
                                shouldAcceptImpulse: (TimeInterval) -> Bool = { _ in true }) -> [Event] {
        guard x.isFinite, y.isFinite, z.isFinite, time.isFinite else { reset(); return [] }
        let current = SIMD3(x, y, z)
        if let lastSampleAt, time <= lastSampleAt { return [] }
        guard let baseline = rest, let previousTime = lastSampleAt, time - previousTime <= 0.15 else {
            reset()
            rest = current
            previous = current
            lastSampleAt = time
            quietSince = time
            return []
        }

        let dt = time - previousTime
        let step = simd_distance(previous, current)
        signalLevel = simd_distance(baseline, current)
        previous = current
        lastSampleAt = time

        if var active = pulse {
            active.peak = max(active.peak, signalLevel)
            // A new permanent orientation or sustained shaking does not settle
            // back near the pre-impact rest vector in this short interval.
            if time - active.start >= maxPulseDuration {
                pulse = nil
                quietSince = nil
                blockedUntil = time + refractory
                rest = current
            } else {
                // With a fitted light-tap threshold, quiet chassis jitter can
                // exceed the uncalibrated release level for several samples.
                let release = max(active.threshold * (profile == nil ? 0.45 : 0.72), active.peak * 0.15)
                if signalLevel > release {
                    active.quietSince = nil
                } else if active.quietSince == nil {
                    active.quietSince = time
                }
                if let settled = active.quietSince, time - settled >= 0.025 {
                    pulse = nil
                    quietSince = settled
                    blockedUntil = active.start + refractory
                    // Correlate hardware input with the impulse itself, even
                    // when the report arrives late. A rejected second impulse
                    // leaves the first one's single-tap deadline intact.
                    guard shouldAcceptImpulse(active.start) else { return advance(to: time) }
                    return acceptImpulse(at: active.start)
                }
                pulse = active
            }
        } else {
            let trigger = max(threshold, (profile == nil ? 5 : 2.5) * noise)
            // Reject gradual motion and require a quiet approach; this also
            // prevents ringing and background vibration from rearming the detector.
            let riseWindow: TimeInterval = profile == nil ? 0.035 : 0.075
            if time >= blockedUntil, let lastArmedAt, time - lastArmedAt <= riseWindow,
               signalLevel >= trigger, step >= trigger * 0.4 {
                pulse = Pulse(start: time, threshold: trigger, peak: signalLevel)
                quietSince = nil
                self.lastArmedAt = nil
            } else {
                let quietLevel = trigger * (profile == nil ? 0.55 : 0.72)
                if signalLevel >= quietLevel {
                    quietSince = nil
                } else {
                    if quietSince == nil { quietSince = time }
                    if let quietSince, time - quietSince >= (profile == nil ? 0.045 : 0.035) { lastArmedAt = time }
                }
                let baselineWeight = 1 - exp(-dt / 0.08)
                rest = baseline + (current - baseline) * baselineWeight
                // Limit each contribution so one missed impulse does not make
                // the next light tap invisible.
                let noiseWeight = 1 - exp(-dt / 0.4)
                noise += (min(step, trigger) - noise) * noiseWeight
            }
        }
        return advance(to: time)
    }

    private mutating func acceptImpulse(at time: TimeInterval) -> [Event] {
        if let firstTapAt {
            if time <= firstTapAt + pairWindow {
                self.firstTapAt = nil
                // A quick third bounce must not start a new single action.
                blockedUntil = time + pairWindow
                return [.doubleTap]
            }
            self.firstTapAt = time
            return [.singleTap, .firstTapPending]
        }
        firstTapAt = time
        return [.firstTapPending]
    }
}
