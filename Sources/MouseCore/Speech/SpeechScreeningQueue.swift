import Foundation

/// Screens finalized speech independently of the task currently using the computer.
/// Only an accepted result should be allowed to interrupt that task.
@MainActor
public final class SpeechScreeningQueue {
    public var isScreening: Bool { worker != nil }

    private struct Utterance {
        let text: String
        let captureID: UUID?
        let timing: PipelineTiming?
        let queueSpan: PipelineTiming.Span?
    }

    private let check: @MainActor (String) async throws -> String?
    private let onAccepted: @MainActor (String, UUID?) -> Void
    private let onIgnored: @MainActor (UUID?) -> Void
    private let onFailure: @MainActor (Error, UUID?) -> Void
    private let onCheckStarted: @MainActor (UUID?, PipelineTiming?) -> Void
    private var pending: [Utterance] = []
    private var current: Utterance?
    private var worker: Task<Void, Never>?
    private var generation = UUID()

    public init(
        check: @escaping @MainActor (String) async throws -> String?,
        onAccepted: @escaping @MainActor (String, UUID?) -> Void,
        onIgnored: @escaping @MainActor (UUID?) -> Void,
        onFailure: @escaping @MainActor (Error, UUID?) -> Void,
        onCheckStarted: @escaping @MainActor (UUID?, PipelineTiming?) -> Void = { _, _ in }
    ) {
        self.check = check
        self.onAccepted = onAccepted
        self.onIgnored = onIgnored
        self.onFailure = onFailure
        self.onCheckStarted = onCheckStarted
    }

    /// Keep utterances separate and intact. The checker reads any current task
    /// context when each item actually starts, not when it is enqueued.
    public func enqueue(_ text: String, captureID: UUID? = nil, timing: PipelineTiming? = nil) {
        pending.append(Utterance(text: text, captureID: captureID, timing: timing,
            queueSpan: timing?.begin("Incoming command queue")))
        guard worker == nil else { return }
        let token = generation
        worker = Task { @MainActor [weak self] in
            await self?.run(generation: token)
        }
    }

    /// Stop, microphone-off, and shutdown invalidate both pending utterances and
    /// results that an uncooperative transport might return after cancellation.
    /// New speech can start a new worker without waiting for that old transport.
    public func cancel() {
        generation = UUID()
        // Finish immediately even when a transport ignores task cancellation.
        // The old worker can no longer change this trace or a replacement's.
        current?.timing?.finish(.cancelled)
        current = nil
        for utterance in pending { utterance.timing?.finish(.cancelled) }
        pending.removeAll()
        worker?.cancel()
        worker = nil
    }

    private func run(generation token: UUID) async {
        while isCurrent(token), !pending.isEmpty {
            let utterance = pending.removeFirst()
            current = utterance
            utterance.timing?.end(utterance.queueSpan, outcome: .succeeded)
            onCheckStarted(utterance.captureID, utterance.timing)
            guard isCurrent(token) else { return }
            let screeningSpan = utterance.timing?.begin("Intent and first-action selection")
            do {
                let command = try await check(utterance.text)
                guard isCurrent(token) else { return }
                utterance.timing?.end(screeningSpan, outcome: .succeeded)
                // Accepted speech now belongs to the command pipeline. Clear
                // ownership before callbacks that may synchronously cancel us.
                current = nil
                if let command {
                    onAccepted(command, utterance.captureID)
                } else {
                    utterance.timing?.finish(.ignored)
                    onIgnored(utterance.captureID)
                }
            } catch {
                guard isCurrent(token) else { return }
                let outcome: PipelineTiming.Outcome = error is CancellationError ? .cancelled : .failed
                utterance.timing?.end(screeningSpan, outcome: outcome)
                utterance.timing?.finish(outcome)
                current = nil
                // A failed item, including a checker that cancels itself, does
                // not prevent subsequent speech from being screened.
                onFailure(error, utterance.captureID)
            }
            // A callback can synchronously cancel or enqueue more speech. The
            // generation check prevents this worker from touching a new run.
        }
        guard isCurrent(token) else { return }
        worker = nil
    }

    private func isCurrent(_ token: UUID) -> Bool {
        generation == token && !Task.isCancelled
    }
}
