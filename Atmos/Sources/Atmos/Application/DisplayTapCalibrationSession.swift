import Foundation
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// A snapshot for Settings. Raw sensor reports stay in the active cue and never reach SwiftUI.
struct DisplayTapCalibrationSession {
    enum Phase { case preparing, recording, retry, tryIt }

    let phase: Phase
    let step: DisplayTapCalibration.Step
    let message: String
    var profile: DisplayTapProfile?
    var sandboxEvent: DisplayTapRecognizer.Event?
}

/// Drives the cues from the same monotonic clock used for the HID reports. A delayed batch
/// cannot be counted as a response to a cue that has only just appeared on the screen.
@MainActor
final class DisplayTapCalibrationWorkflow {
    private var training = DisplayTapCalibration()
    private var samples: [DisplayTapCalibration.Sample] = []
    private var cueStarted: TimeInterval = 0
    private var transitionAt: TimeInterval?
    private var automaticRetries = 0
    private var practiceRecognizer: DisplayTapRecognizer?
    private(set) var session: DisplayTapCalibrationSession

    init(at now: TimeInterval) {
        session = Self.preparation(for: .baseline)
        transitionAt = now + 1.0
    }

    /// Returns true only when the visible cue changes, so 100 Hz motion never redraws Settings.
    func receive(time: TimeInterval, acceleration: SIMD3<Double>, deliveredAt now: TimeInterval,
                 hadInputSince: (TimeInterval) -> Bool, acceptImpulse: (TimeInterval) -> Bool) -> Bool {
        switch session.phase {
        case .preparing, .retry:
            guard let transitionAt, now >= transitionAt else { return false }
            beginCue(at: now)
            return true
        case .recording:
            guard time >= cueStarted, let transitionAt else { return false }
            guard time >= transitionAt else {
                samples.append(.init(time: time, acceleration: acceleration))
                return false
            }
            if hadInputSince(cueStarted) {
                retry(message: "A key or trackpad click occurred during the cue. Keep your hands away from the controls.",
                      at: now, automatically: true)
            } else {
                evaluate(at: now)
            }
            return true
        case .tryIt:
            let events = practiceRecognizer?.sample(x: acceleration.x, y: acceleration.y, z: acceleration.z,
                                                    at: time, shouldAcceptImpulse: acceptImpulse)
            if let last = events?.last {
                session.sandboxEvent = last
                return true
            }
            if session.sandboxEvent == .firstTapPending, practiceRecognizer?.pendingDeadline == nil {
                session.sandboxEvent = nil
                return true
            }
            return false
        }
    }

    func retryStep(at now: TimeInterval) {
        guard session.phase == .retry else { return }
        automaticRetries = 0
        prepare(at: now)
    }

    func redoSingles(at now: TimeInterval) {
        guard session.phase == .tryIt else { return }
        training.redoSingles()
        prepare(at: now)
    }

    func redoDoubles(at now: TimeInterval) {
        guard session.phase == .tryIt else { return }
        training.redoDoubles()
        prepare(at: now)
    }

    private func beginCue(at now: TimeInterval) {
        cueStarted = now
        let instruction: String
        let duration: TimeInterval
        switch training.step {
        case .baseline:
            instruction = "Leave the MacBook resting on the surface you normally use."
            duration = 2
        case .single:
            instruction = "Tap the display once with your usual pressure, then let it settle."
            duration = 2.8
        case .double:
            instruction = "Tap the display twice at your natural pace, then let it settle."
            duration = 3.2
        case .complete: return
        }
        samples.removeAll(keepingCapacity: true)
        transitionAt = now + duration
        session = .init(phase: .recording, step: training.step, message: instruction)
    }

    private func evaluate(at now: TimeInterval) {
        do {
            let profile = try training.evaluate(samples)
            samples.removeAll(keepingCapacity: true)
            automaticRetries = 0
            if let profile {
                practiceRecognizer = DisplayTapRecognizer(profile: profile)
                transitionAt = nil
                session = .init(phase: .tryIt, step: .complete,
                                message: "Practice a single or double tap. Your taps only update this preview.", profile: profile)
            } else {
                prepare(at: now)
            }
        } catch {
            let missedCue = (error as? DisplayTapCalibration.Failure) == .noTap
            retry(message: error.localizedDescription, at: now, automatically: !missedCue)
        }
    }

    private func prepare(at now: TimeInterval) {
        practiceRecognizer = nil
        samples.removeAll(keepingCapacity: true)
        transitionAt = now + 1.0
        session = Self.preparation(for: training.step)
    }

    private static func preparation(for step: DisplayTapCalibration.Step) -> DisplayTapCalibrationSession {
        let instruction = step == .baseline ? "Rest your hands and let the MacBook settle." : "Wait for the ring before you tap."
        return .init(phase: .preparing, step: step, message: instruction)
    }

    private func retry(message: String, at now: TimeInterval, automatically: Bool) {
        samples.removeAll(keepingCapacity: true)
        // Give an unattended wizard a stable pause, even on a continuously vibrating surface.
        let willRetry = automatically && automaticRetries < 2
        transitionAt = willRetry ? now + 1.5 : nil
        automaticRetries += 1
        session = .init(phase: .retry, step: training.step, message: message)
    }
}
