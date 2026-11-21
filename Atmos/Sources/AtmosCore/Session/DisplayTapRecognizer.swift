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

    public static let physicalInputTail: TimeInterval = 0.12

    private let profile: DisplayTapProfile
    private let validProfile: Bool

    private struct Pulse {
        let start: TimeInterval
        let threshold: Double
        var peak: Double
        var peakVector: SIMD3<Double>
        var hasShape: Bool
        var quietSince: TimeInterval?
    }

    private var maxPulseDuration: TimeInterval { max(0.115, profile.ringingInterval + 0.025) }
    private var rest: SIMD3<Double>?
    private var previous = SIMD3<Double>.zero
    private var lastSampleAt: TimeInterval?
    private var quietSince: TimeInterval?
    private var lastArmedAt: TimeInterval?
    private var blockedUntil: TimeInterval = 0
    private var noise = 0.0
    private var pulse: Pulse?
    private var firstTapAt: TimeInterval?
    private var settledOnsets: [TimeInterval] = []

    public init(profile: DisplayTapProfile) {
        self.profile = profile
        validProfile = profile.isValid
    }

    public var pendingDeadline: TimeInterval? {
        guard let firstTapAt else { return nil }
        let deadline = firstTapAt + profile.doubleTapInterval
        var resolveAt = deadline
        if let pulse, pulse.start <= deadline {
            resolveAt = max(resolveAt, pulse.start + maxPulseDuration)
        }
        if let waiting = settledOnsets.last(where: { $0 <= deadline }) {
            resolveAt = max(resolveAt, waiting + Self.physicalInputTail)
        }
        return resolveAt
    }

    public mutating func reset() {
        self = Self(profile: profile)
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
        guard validProfile else { return [] }
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
        let precedingLevel = simd_distance(baseline, previous)
        let signalLevel = simd_distance(baseline, current)
        previous = current
        lastSampleAt = time

        if var active = pulse {
            if signalLevel > active.peak {
                active.peak = signalLevel
                active.peakVector = current - baseline
            }
            if time - active.start <= 0.055, signalLevel >= active.threshold * 0.35 { active.hasShape = true }
            // A new permanent orientation or sustained shaking does not settle
            // back near the pre-impact rest vector in this short interval.
            if time - active.start >= maxPulseDuration {
                pulse = nil
                quietSince = nil
                blockedUntil = time + profile.ringingInterval
                rest = current
            } else {
                // With a fitted light-tap threshold, quiet chassis jitter can
                // exceed the uncalibrated release level for several samples.
                let release = max(active.threshold * 0.62, active.peak * 0.15)
                if signalLevel > release {
                    active.quietSince = nil
                } else if active.quietSince == nil {
                    active.quietSince = time
                }
                if let settled = active.quietSince, time - settled >= 0.025 {
                    pulse = nil
                    quietSince = settled
                    blockedUntil = active.start + profile.ringingInterval
                    if active.hasShape, active.peak <= profile.maximumPeak,
                       abs(simd_dot(active.peakVector, profile.axis)) >= active.peak * 0.62 {
                        settledOnsets.append(active.start)
                    }
                } else {
                    pulse = active
                }
            }
        } else {
            let trigger = max(profile.threshold, 4 * noise)
            // Reject gradual motion and require a quiet approach; this also
            // prevents ringing and background vibration from rearming the detector.
            if time >= blockedUntil, let lastArmedAt, time - lastArmedAt <= 0.055,
               signalLevel >= trigger, step >= trigger * 0.4 {
                pulse = Pulse(start: time, threshold: trigger, peak: signalLevel,
                              peakVector: current - baseline, hasShape: precedingLevel >= trigger * 0.35)
                quietSince = nil
                self.lastArmedAt = nil
            } else {
                let quietLevel = trigger * 0.62
                if signalLevel >= quietLevel {
                    quietSince = nil
                } else {
                    if quietSince == nil { quietSince = time }
                    if let quietSince, time - quietSince >= 0.045 { lastArmedAt = time }
                }
                let baselineWeight = 1 - exp(-dt / 0.08)
                rest = baseline + (current - baseline) * baselineWeight
                // Limit each contribution so one missed impulse does not make
                // the next light tap invisible.
                let noiseWeight = 1 - exp(-dt / 0.4)
                noise += (min(step, trigger) - noise) * noiseWeight
            }
        }
        guard !settledOnsets.isEmpty else { return advance(to: time) }
        // A chassis impulse can settle before the corresponding click or key
        // event arrives. Discard vetoed onsets as soon as input is known, and
        // only classify once sensor time covers the entire correlation window.
        settledOnsets.removeAll { !shouldAcceptImpulse($0) }
        var events = [Event]()
        while let onset = settledOnsets.first, time >= onset + Self.physicalInputTail {
            settledOnsets.removeFirst()
            let accepted = acceptImpulse(at: onset)
            events += accepted
            if accepted.last == .doubleTap {
                // A third bounce may already have started during validation.
                settledOnsets.removeAll { $0 < blockedUntil }
                if let pulse, pulse.start < blockedUntil { self.pulse = nil }
            }
        }
        events += advance(to: time)
        return events
    }

    private mutating func acceptImpulse(at time: TimeInterval) -> [Event] {
        if let firstTapAt {
            if time <= firstTapAt + profile.doubleTapInterval {
                self.firstTapAt = nil
                // A quick third bounce must not start a new single action.
                blockedUntil = time + profile.doubleTapInterval
                return [.doubleTap]
            }
            self.firstTapAt = time
            return [.singleTap, .firstTapPending]
        }
        firstTapAt = time
        return [.firstTapPending]
    }
}
