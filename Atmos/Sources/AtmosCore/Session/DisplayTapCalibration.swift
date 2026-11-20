import Foundation
import simd

/// A fit stores three aggregate measurements. Raw sensor traces stay in the
/// calibration session and never enter the persisted profile.
public struct DisplayTapProfile: Codable, Equatable, Sendable {
    public static let thresholdRange = 0.001...0.120
    public let threshold: Double
    public let ringingInterval: TimeInterval
    public let doubleTapInterval: TimeInterval

    public init(threshold: Double, ringingInterval: TimeInterval, doubleTapInterval: TimeInterval) {
        self.threshold = threshold
        self.ringingInterval = ringingInterval
        self.doubleTapInterval = doubleTapInterval
    }

    public var isValid: Bool {
        Self.thresholdRange.contains(threshold) && (0.065...0.32).contains(ringingInterval)
            && (0.16...0.85).contains(doubleTapInterval) && ringingInterval + 0.025 < doubleTapInterval
    }
}

public struct DisplayTapCalibration {
    public enum Step: Equatable, Sendable { case baseline, single(Int), double(Int), complete }
    public struct Sample: Sendable {
        public let time: TimeInterval
        public let acceleration: SIMD3<Double>
        public init(time: TimeInterval, acceleration: SIMD3<Double>) {
            self.time = time
            self.acceleration = acceleration
        }
    }

    public enum Failure: LocalizedError, Equatable {
        case interrupted, movingBaseline, noTap, unclearMotion, wrongCount(Int), unclearPair, inconsistent, incompatibleSingle
        public var errorDescription: String? {
            switch self {
            case .interrupted: return "The motion sensor missed part of this sample. Try again."
            case .movingBaseline: return "Keep the Mac still while it measures the background vibration."
            case .noTap: return "No clear tap was detected. Try a slightly firmer tap."
            case .unclearMotion: return "Let the display settle, then tap without moving the lid."
            case .wrongCount(let count):
                return count == 1 ? "Try one tap, then leave the display still." : "Try two distinct taps, then leave the display still."
            case .unclearPair: return "Use two distinct taps with a short pause between them."
            case .inconsistent: return "That sample differed from the earlier taps. Try again at your usual strength."
            case .incompatibleSingle: return "That tap could not be separated from your saved double taps. Let the lid settle and repeat this single tap."
            }
        }
    }

    private struct Impact {
        let start: TimeInterval
        var end: TimeInterval
        var peak: Double
    }
    private struct Trial {
        let samples: [Sample]
        let impacts: [Impact]
    }
    private var noiseThreshold: Double?
    private var quietBaseline: [Sample] = []
    private var singles: [Trial] = []
    private var doubles: [Trial] = []
    private var fitted: DisplayTapProfile?
    public init() {}

    public var step: Step {
        if noiseThreshold == nil { return .baseline }
        if singles.count < 3 { return .single(singles.count + 1) }
        if doubles.count < 3 { return .double(doubles.count + 1) }
        return .complete
    }

    public mutating func redoSingles() { singles.removeAll(); fitted = nil }
    public mutating func redoDoubles() { doubles.removeAll(); fitted = nil }

    /// Feed a whole cued window, including still samples before and after the
    /// gesture. Invalid input leaves the current trial available to repeat.
    public mutating func evaluate(_ samples: [Sample]) throws -> DisplayTapProfile? {
        let current = step
        if current == .complete { return fitted }
        try Self.checkCoverage(samples, minimumSpan: current == .baseline ? 1.85 : 0.75)
        if current == .baseline {
            noiseThreshold = try Self.measureNoise(samples)
            quietBaseline = samples
            return nil
        }
        guard let noiseThreshold else { throw Failure.interrupted }
        switch current {
        case .single:
            let bursts = try Self.findBursts(samples, threshold: noiseThreshold)
            let trial = Trial(samples: samples, impacts: try Self.group(bursts, count: 1, ringLimit: 0.27))
            let next = singles + [trial]
            // Validate even early samples with the same online detector used
            // after saving. A later incompatible trial cannot poison the fit.
            _ = try fit(next, doubles: [], noiseThreshold: noiseThreshold)
            var updated: DisplayTapProfile?
            if !doubles.isEmpty {
                // A redo replaces a single only when it remains compatible with
                // the retained pairs. Both categories survive a rejected retry.
                do { updated = try fit(next, doubles: doubles, noiseThreshold: noiseThreshold) }
                catch { throw Failure.incompatibleSingle }
            }
            singles = next
            if singles.count == 3, doubles.count == 3, let updated {
                fitted = updated
                return updated
            }
        case .double:
            // The three cued singles give an observed lower bound on the
            // user's impact strength. A much smaller room vibration late in
            // the double-tap window should not be labeled a third finger tap.
            let singlePeak = singles.compactMap { $0.impacts.first?.peak }.min()!
            let bursts = try Self.findBursts(samples, threshold: max(noiseThreshold, singlePeak * 0.42))
            let ringLimit = min(0.28, Self.maxSpan(singles) + 0.04)
            let impacts = try Self.group(bursts, count: 2, ringLimit: ringLimit)
            let next = doubles + [Trial(samples: samples, impacts: impacts)]
            let candidate = try fit(singles, doubles: next, noiseThreshold: noiseThreshold)
            doubles = next
            if doubles.count == 3 { fitted = candidate; return candidate }
        case .baseline, .complete: break
        }
        return nil
    }

    private static func checkCoverage(_ samples: [Sample], minimumSpan: TimeInterval) throws {
        guard let first = samples.first, let last = samples.last,
              (32...2048).contains(samples.count), last.time - first.time >= minimumSpan else { throw Failure.interrupted }
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
                active.peak = max(active.peak, level)
                if level > max(threshold * 0.72, active.peak * 0.14) { active.end = sample.time }
                guard active.end - active.start < 0.265 else { throw Failure.unclearMotion }
                if sample.time - active.end >= 0.035 {
                    if active.peak >= minimumPeak { bursts.append(active) }
                    burst = nil
                } else { burst = active }
            } else if level >= threshold, step >= threshold * 0.35 {
                burst = Impact(start: sample.time, end: sample.time, peak: level)
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
                    impacts[impacts.count - 1].peak = max(impact.peak, burst.peak)
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

    private func fit(_ singles: [Trial], doubles: [Trial], noiseThreshold: Double) throws -> DisplayTapProfile {
        let trials = singles + doubles
        let ringing = max(0.075, Self.maxSpan(trials) + 0.035)
        let pairGaps = doubles.map { $0.impacts[1].start - $0.impacts[0].start }
        guard ringing <= 0.32, pairGaps.allSatisfy({ $0 > ringing + 0.01 }) else { throw Failure.unclearPair }
        let longest = pairGaps.max() ?? 0.25
        let window = max(0.16, ringing + 0.045, longest + max(0.035, longest * 0.16))
        let weakest = trials.flatMap(\.impacts).map(\.peak).min()!
        // Try the midpoint of the noise/tap separation first. Replay the actual
        // trials before committing so weak or differently shaped taps survive.
        let quiet = Trial(samples: quietBaseline, impacts: [])
        for fraction in [0.55, 0.70, 0.85, 0.40, 0.25, 0.10] {
            let threshold = min(DisplayTapProfile.thresholdRange.upperBound,
                                max(DisplayTapProfile.thresholdRange.lowerBound, noiseThreshold + (weakest - noiseThreshold) * fraction))
            let profile = DisplayTapProfile(threshold: threshold, ringingInterval: ringing, doubleTapInterval: min(0.85, window))
            if profile.isValid, Self.replays(quiet, with: profile),
               trials.allSatisfy({ Self.replays($0, with: profile) }) { return profile }
        }
        throw Failure.inconsistent
    }

    private static func replays(_ trial: Trial, with profile: DisplayTapProfile) -> Bool {
        var recognizer = DisplayTapRecognizer(profile: profile)
        var events: [DisplayTapRecognizer.Event] = []
        for sample in trial.samples {
            let a = sample.acceleration
            events += recognizer.sample(x: a.x, y: a.y, z: a.z, at: sample.time)
        }
        if trial.impacts.isEmpty { return events.isEmpty }
        if trial.impacts.count == 2 { return events == [.firstTapPending, .doubleTap] }
        // A tap late in the cue may still be waiting for its pair deadline.
        return events == [.firstTapPending, .singleTap]
            || (events == [.firstTapPending] && recognizer.pendingDeadline != nil)
    }
}
