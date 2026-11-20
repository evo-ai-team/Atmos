import AppKit
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// Visual and semantic evidence from one foreground application. The process and
/// capture time also determine whether a speech-endpoint prefetch is still usable.
struct ScreenObservation: Sendable {
    let frame: ScreenshotFrame
    let accessibility: AccessibilitySnapshot
    let processID: Int32
    let capturedAt: TimeInterval
}

@MainActor
struct ScreenObserver {
    let computer: NativeComputer
    let accessibility: AccessibilityController

    func capture(timing: PipelineTiming? = nil) async throws -> ScreenObservation {
        let stage = timing?.begin("Screen observation (image and accessibility)")
        var accessibilityStage: PipelineTiming.Span?
        // AX runs on its own actor, so an unresponsive app cannot block speech or
        // the notch. Retry once if focus changes while collecting the image/tree.
        do {
            for attempt in 0..<2 {
                if attempt > 0 { timing?.mark("Foreground changed; retrying observation") }
                try Task.checkCancellation()
                let processID = foregroundProcessID
                let capturedAt = ProcessInfo.processInfo.systemUptime
                let frame = try await computer.capture(timing: timing)
                try Task.checkCancellation()
                // Start before crossing actors. The nested capture timer starts
                // on the AX actor, making any scheduling backlog visible too.
                accessibilityStage = timing?.begin("Accessibility actor scheduling and capture")
                let tree = try await accessibility.capture(processID: processID, frame: frame, timing: timing)
                timing?.end(accessibilityStage, outcome: Task.isCancelled ? .cancelled : .succeeded)
                accessibilityStage = nil
                try Task.checkCancellation()
                if foregroundProcessID == processID {
                    timing?.end(stage)
                    return ScreenObservation(frame: frame, accessibility: tree,
                                             processID: processID, capturedAt: capturedAt)
                }
            }
            throw AtmosError.configuration("The foreground app changed while Atmos was observing it. Repeat the command.")
        } catch {
            timing?.end(accessibilityStage, outcome: error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            timing?.end(stage, outcome: error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            throw error
        }
    }

    /// Call immediately before dispatch, even for a freshly captured observation.
    func validate(_ observation: ScreenObservation) throws {
        try computer.validateFrame(observation.frame)
        guard foregroundProcessID == observation.processID else {
            throw AtmosError.configuration("The foreground app changed before Atmos could act. Repeat the command in the intended app.")
        }
    }

    private var foregroundProcessID: Int32 {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }
}
