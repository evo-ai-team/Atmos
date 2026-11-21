import Foundation
import simd
#if SWIFT_PACKAGE
import AtmosCore
#endif

struct DisplayTapCalibrationSession {
    enum Phase { case ready, preparing, recording, retry, complete }

    let phase: Phase
    let step: DisplayTapCalibration.Step
    let message: String
    var profile: DisplayTapProfile?
}

/// Captures one example per button press. The short quiet lead-in discards
/// vibration from the click and gives each gesture its own background sample.
@MainActor
final class DisplayTapCalibrationWorkflow {
    private var training = DisplayTapCalibration()
    private var baseline: [DisplayTapCalibration.Sample] = []
    private var samples: [DisplayTapCalibration.Sample] = []
    private var collectFrom: TimeInterval = 0
    private var cueShownAt: TimeInterval = 0
    private var lastMotion: TimeInterval?
    private(set) var session = DisplayTapCalibrationSession(phase: .ready, step: .single, message: "")

    func record(at now: TimeInterval) {
        guard session.phase == .ready || session.phase == .retry else { return }
        baseline.removeAll(keepingCapacity: true)
        samples.removeAll(keepingCapacity: true)
        lastMotion = nil
        collectFrom = now + 0.20
        session = .init(phase: .preparing, step: training.step, message: "Let the display settle.")
    }

    func redoSingle(at now: TimeInterval) {
        guard session.phase == .complete || (session.step == .double && (session.phase == .ready || session.phase == .retry)) else { return }
        training.redoSingle()
        session = .init(phase: .ready, step: .single, message: "")
        record(at: now)
    }

    func redoDouble(at now: TimeInterval) {
        guard session.phase == .complete else { return }
        training.redoDouble()
        session = .init(phase: .ready, step: .double, message: "")
        record(at: now)
    }

    /// Only a change in the prompt is published to SwiftUI. HID samples that
    /// predate a visible prompt cannot count as a response to it.
    func receive(time: TimeInterval, acceleration: SIMD3<Double>, deliveredAt now: TimeInterval,
                 hadInputSince: (TimeInterval) -> Bool) -> Bool {
        switch session.phase {
        case .ready, .retry, .complete:
            return false
        case .preparing:
            guard time >= collectFrom else { return false }
            baseline.append(.init(time: time, acceleration: acceleration))
            guard let first = baseline.first, time - first.time >= 0.30 else { return false }
            if hadInputSince(collectFrom) {
                retry("Another key or click was detected. Record this gesture again.")
            } else {
                // Seed the detector with still samples so a quick tap immediately
                // after the new prompt can arm at the user's normal strength.
                samples = baseline.filter { $0.time >= time - 0.14 }
                cueShownAt = now
                session = .init(phase: .recording, step: training.step,
                                message: training.step == .single ? "Tap the display once now." : "Tap the display twice now.")
            }
            return true
        case .recording:
            let sample = DisplayTapCalibration.Sample(time: time, acceleration: acceleration)
            samples.append(sample)
            guard time >= cueShownAt else {
                // Keep continuity for batched reports, but disallow a gesture
                // that occurred before its visible cue.
                if let rest = baseline.last, simd_distance(rest.acceleration, acceleration) >= 0.006 {
                    retry("Record again and tap when prompted.")
                    return true
                }
                return false
            }
            if let rest = baseline.last, simd_distance(rest.acceleration, acceleration) >= 0.006 {
                lastMotion = time
            }
            let settled = lastMotion.map { time - $0 >= 0.80 } ?? false
            // At the end of the response window, give an in-flight pair time
            // for its second impact and quiet tail. Sustained motion is bounded.
            let timeout: TimeInterval = lastMotion == nil ? 4.0 : 5.7
            guard settled || time - cueShownAt >= timeout else { return false }
            if hadInputSince(collectFrom) {
                retry("Another key or click was detected. Record this gesture again.")
            } else {
                do {
                    if let profile = try training.evaluate(samples, baseline: baseline, cueAt: cueShownAt) {
                        session = .init(phase: .complete, step: .complete, message: "", profile: profile)
                    } else {
                        session = .init(phase: .ready, step: .double, message: "")
                    }
                } catch { retry(error.localizedDescription) }
            }
            return true
        }
    }

    private func retry(_ message: String) {
        session = .init(phase: .retry, step: training.step, message: message)
    }
}
