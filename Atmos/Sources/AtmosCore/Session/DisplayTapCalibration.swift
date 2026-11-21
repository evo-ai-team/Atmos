import Foundation
import simd

/// Only fitted measurements persist. Profiles from the older fixed-threshold
/// detector lack the version and impact signature required for activation.
public struct DisplayTapProfile: Codable, Equatable, Sendable {
    public static let thresholdRange = 0.006...0.20
    public let version: Int
    public let threshold: Double
    public let maximumPeak: Double
    public let axis: SIMD3<Double>
    public let ringingInterval: TimeInterval
    public let doubleTapInterval: TimeInterval

    public init(threshold: Double, maximumPeak: Double, axis: SIMD3<Double>,
                ringingInterval: TimeInterval, doubleTapInterval: TimeInterval) {
        version = 2
        self.threshold = threshold
        self.maximumPeak = maximumPeak
        self.axis = axis
        self.ringingInterval = ringingInterval
        self.doubleTapInterval = doubleTapInterval
    }

    public var isValid: Bool {
        version == 2 && Self.thresholdRange.contains(threshold) && maximumPeak > threshold
            && maximumPeak <= 16 && (0.99...1.01).contains(simd_length(axis))
            && (0.065...0.32).contains(ringingInterval) && (0.16...0.85).contains(doubleTapInterval)
            && ringingInterval + 0.025 < doubleTapInterval
    }
}

public struct DisplayTapCalibration {
    public enum Step: Equatable, Sendable { case single, double, complete }
    public struct Sample: Sendable {
        public let time: TimeInterval
        public let acceleration: SIMD3<Double>
        public init(time: TimeInterval, acceleration: SIMD3<Double>) {
            self.time = time
            self.acceleration = acceleration
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case interrupted, movingBaseline, beforeCue, noTap, unclearMotion, wrongCount(Int), unclearPair, inconsistent
        public var errorDescription: String? {
            switch self {
            case .interrupted: return "The motion sensor missed part of this sample. Try again."
            case .movingBaseline: return "Keep the Mac still while it measures the background vibration."
            case .beforeCue: return "The display moved before recording began. Record again, then tap when prompted."
            case .noTap: return "No clear tap was detected. Try a slightly firmer tap."
            case .unclearMotion: return "Let the display settle, then tap without moving the lid."
            case .wrongCount(let count):
                return count == 1 ? "Try one tap, then leave the display still." : "Try two distinct taps, then leave the display still."
            case .unclearPair: return "Use two distinct taps with a short pause between them."
            case .inconsistent: return "Tap the same spot on the display with similar pressure each time."
            }
        }
    }

    private struct Impact {
        let start: TimeInterval
        var end: TimeInterval
        var peak: Double
        var direction: SIMD3<Double>
    }
    private struct Trial {
        let baseline: [Sample]
        let noiseThreshold: Double
        let samples: [Sample]
        let impacts: [Impact]
    }
    private var single: Trial?
    private var fitted: DisplayTapProfile?
    public init() {}

    public var step: Step { fitted != nil ? .complete : single == nil ? .single : .double }

    public mutating func redoSingle() { single = nil; fitted = nil }
    public mutating func redoDouble() { fitted = nil }

    /// Each click captures the quiet lead-in and one gesture. Keep an accepted
    /// single across failed double attempts, and validate against the actual
    /// runtime classifier before accepting either recording.
    public mutating func evaluate(_ samples: [Sample], baseline: [Sample], cueAt: TimeInterval) throws -> DisplayTapProfile? {
        if let fitted { return fitted }
        try Self.checkCoverage(baseline, minimumSpan: 0.20)
        try Self.checkCoverage(samples, minimumSpan: 0.35)
        let noise = try Self.measureNoise(baseline)
        let detectionFloor = max(Self.minimumImpact * 0.65, noise, (single?.impacts.first?.peak ?? 0) * 0.42)
        let bursts = try Self.findBursts(samples, threshold: detectionFloor)
        // The quiet prefix arms replay. It can never supply a tap in response
        // to a prompt that had not yet appeared on screen.
        guard bursts.allSatisfy({ $0.start > cueAt }) else { throw Failure.beforeCue }
        let ringLimit = single.map { min(0.28, Self.maxSpan([$0]) + 0.04) } ?? 0.27
        let impacts = try Self.group(bursts, count: single == nil ? 1 : 2, ringLimit: ringLimit)
        guard impacts.allSatisfy({ $0.peak >= max(Self.minimumImpact, noise * 2.0) }) else { throw Failure.noTap }
        let trial = Trial(baseline: baseline, noiseThreshold: noise, samples: samples, impacts: impacts)
        if let single {
            let profile = try Self.fit([single, trial])
            fitted = profile
            return profile
        }
        _ = try Self.fit([trial])
        single = trial
        return nil
    }

    private static let minimumImpact = 0.008

    private static func checkCoverage(_ samples: [Sample], minimumSpan: TimeInterval) throws {
        guard let first = samples.first, let last = samples.last,
              (12...2048).contains(samples.count), last.time - first.time >= minimumSpan else { throw Failure.interrupted }
        var previous: TimeInterval?
        for sample in samples {
            let a = sample.acceleration
            guard sample.time.isFinite, a.x.isFinite, a.y.isFinite, a.z.isFinite,
                  simd_length(a) < 16 else { throw Failure.interrupted }
            if let previous, !(sample.time > previous && sample.time - previous <= 0.11) { throw Failure.interrupted }
            previous = sample.time
        }
    }

    /// The first HID report can be several milligravities off the local mean.
    /// A median across the short pre-cue quiet prefix avoids mistaking its
    /// return to normal for an impact or holding a biased rest vector.
    private static func initialRest(_ samples: [Sample]) -> SIMD3<Double> {
        let prefix = samples.prefix { $0.time <= samples[0].time + 0.065 }
        func median(_ axis: Int) -> Double {
            let values = prefix.map { $0.acceleration[axis] }.sorted()
            return values[values.count / 2]
        }
        return SIMD3(median(0), median(1), median(2))
    }

    private static func measureNoise(_ samples: [Sample]) throws -> Double {
        let initial = initialRest(samples)
        var rest = initial
        var previous = samples[0]
        var levels: [Double] = []
        var steps: [Double] = []
        for sample in samples.dropFirst() {
            let delta = sample.acceleration - rest
            levels.append(simd_length(delta))
            steps.append(simd_distance(sample.acceleration, previous.acceleration))
            guard simd_distance(sample.acceleration, initial) < 0.035 else {
                throw Failure.movingBaseline
            }
            rest += delta * (1 - exp(-(sample.time - previous.time) / 0.08))
            previous = sample
        }
        let sorted = levels.sorted()
        let quiet = sorted[Int(Double(sorted.count - 1) * 0.95)]
        let sortedSteps = steps.sorted()
        let jitter = sortedSteps[Int(Double(sortedSteps.count - 1) * 0.95)]
        guard quiet < 0.010, sorted.last! < max(0.012, quiet * 4.0) else { throw Failure.movingBaseline }
        return max(0.0008, quiet * 2.1, jitter * 1.30)
    }

    private static func findBursts(_ samples: [Sample], threshold: Double) throws -> [Impact] {
        var rest = initialRest(samples)
        var previous = samples[0]
        var burst: Impact?
        var bursts: [Impact] = []
        let minimumPeak = threshold * 1.20
        for sample in samples.dropFirst() {
            let level = simd_distance(rest, sample.acceleration)
            let step = simd_distance(previous.acceleration, sample.acceleration)
            if var active = burst {
                if level > active.peak {
                    active.peak = level
                    active.direction = sample.acceleration - rest
                }
                if level > max(threshold * 0.72, active.peak * 0.14) { active.end = sample.time }
                guard active.end - active.start < 0.265 else { throw Failure.unclearMotion }
                if sample.time - active.end >= 0.035 {
                    if active.peak >= minimumPeak { bursts.append(active) }
                    burst = nil
                } else { burst = active }
            } else if level >= threshold, step >= threshold * 0.35 {
                burst = Impact(start: sample.time, end: sample.time, peak: level, direction: sample.acceleration - rest)
            } else {
                rest += (sample.acceleration - rest) * (1 - exp(-(sample.time - previous.time) / 0.08))
            }
            previous = sample
        }
        if let burst, burst.peak >= minimumPeak { throw Failure.unclearMotion }
        guard let last = bursts.last else { throw Failure.noTap }
        guard bursts[0].start - samples[0].time >= 0.06, samples.last!.time - last.end >= 0.07 else {
            throw Failure.unclearMotion
        }
        return bursts
    }

    /// Short, weaker rebounds belong to an impact. Comparable peaks that are
    /// far enough apart must match the count requested by the cue.
    private static func group(_ bursts: [Impact], count: Int, ringLimit: TimeInterval) throws -> [Impact] {
        var impacts: [Impact] = []
        for burst in bursts {
            if let impact = impacts.last {
                let gap = burst.start - impact.start
                let rebound = gap <= ringLimit && burst.peak <= impact.peak * 0.58
                if gap < 0.065 || rebound {
                    impacts[impacts.count - 1].end = burst.end
                    if burst.peak > impact.peak {
                        impacts[impacts.count - 1].peak = burst.peak
                        impacts[impacts.count - 1].direction = burst.direction
                    }
                    continue
                }
            }
            impacts.append(burst)
        }
        guard impacts.count == count else { throw Failure.wrongCount(count) }
        if count == 2 {
            let gap = impacts[1].start - impacts[0].start
            guard (0.085...0.74).contains(gap), impacts[1].start - impacts[0].end >= 0.04 else {
                throw Failure.unclearPair
            }
        }
        return impacts
    }

    private static func maxSpan(_ trials: [Trial]) -> TimeInterval {
        trials.flatMap(\.impacts).map { $0.end - $0.start }.max() ?? 0
    }

    private static func fit(_ trials: [Trial]) throws -> DisplayTapProfile {
        let impacts = trials.flatMap(\.impacts)
        let peaks = impacts.map(\.peak).sorted()
        let weakest = peaks[0]
        let strongest = peaks[peaks.count - 1]
        guard weakest >= strongest * 0.45 else { throw Failure.inconsistent }
        let reference = simd_normalize(impacts[0].direction)
        let aligned = impacts.map { impact -> SIMD3<Double> in
            let unit = simd_normalize(impact.direction)
            return simd_dot(reference, unit) < 0 ? -unit : unit
        }
        let axis = simd_normalize(aligned.reduce(.zero, +))
        guard aligned.allSatisfy({ simd_dot(axis, $0) >= 0.7 }) else { throw Failure.inconsistent }
        let ringing = max(0.09, maxSpan(trials) + 0.035)
        let gap = trials.last.flatMap { $0.impacts.count == 2 ? $0.impacts[1].start - $0.impacts[0].start : nil }
        guard ringing <= 0.32, gap.map({ $0 > ringing + 0.01 }) ?? true else { throw Failure.unclearPair }
        let window = max(ringing + 0.05, (gap ?? 0.25) * 1.18 + 0.025)
        let noise = trials.map(\.noiseThreshold).max()!
        let threshold = max(DisplayTapProfile.thresholdRange.lowerBound, weakest * 0.76,
                            peaks[peaks.count / 2] * 0.63, noise * 1.7)
        let profile = DisplayTapProfile(threshold: threshold, maximumPeak: min(16, strongest * 3),
                                        axis: axis, ringingInterval: ringing, doubleTapInterval: min(0.85, max(0.16, window)))
        guard profile.isValid, trials.allSatisfy({ trial in
            events(trial.baseline, profile: profile).isEmpty &&
            events(trial.samples, profile: profile) == [.firstTapPending, trial.impacts.count == 1 ? .singleTap : .doubleTap]
        }) else { throw Failure.inconsistent }
        return profile
    }

    private static func events(_ samples: [Sample], profile: DisplayTapProfile) -> [DisplayTapRecognizer.Event] {
        var recognizer = DisplayTapRecognizer(profile: profile)
        var events = samples.flatMap { sample in
            recognizer.sample(x: sample.acceleration.x, y: sample.acceleration.y, z: sample.acceleration.z, at: sample.time)
        }
        // A trailing quiet interval was observed. For a single recorded just
        // before the end of its window, validate the pending classification too.
        if events == [.firstTapPending], recognizer.pendingDeadline != nil { events.append(.singleTap) }
        return events
    }
}
