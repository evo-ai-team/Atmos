import Foundation

/// Advances one live analyzer's boundary without running overlapping finalizations.
/// This does not establish that the analyzer's result stream has been consumed.
@MainActor
public final class SpeechBoundarySynchronizer {
    public private(set) var completedThrough: TimeInterval = 0

    private let finalize: @MainActor (TimeInterval) async throws -> Void
    private let onFailure: @MainActor (Error) -> Void
    private var requestedThrough: TimeInterval = 0
    private var worker: Task<Void, Never>?
    private var lifecycle = UUID()
    private var retired = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        finalize: @escaping @MainActor (TimeInterval) async throws -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) {
        self.finalize = finalize
        self.onFailure = onFailure
    }

    /// Repeated requests only advance the pending target; an active call finishes
    /// before the worker finalizes through the newest requested boundary.
    public func request(through time: TimeInterval) {
        guard !retired, time.isFinite, time > completedThrough else { return }
        requestedThrough = max(requestedThrough, time)
        guard worker == nil else { return }
        let token = lifecycle
        worker = Task { @MainActor [weak self] in
            await self?.run(lifecycle: token)
        }
    }

    /// Permanently retires this analyzer's synchronizer. Create a new instance
    /// for a new analyzer; cancellation cannot undo an already-started finalize.
    public func cancel() {
        guard !retired else { return }
        retired = true
        lifecycle = UUID()
        worker?.cancel()
        worker = nil
        finishWaiters()
    }

    /// For diagnostics and tests only. Returns once requested work completes,
    /// fails, or is cancelled, not when the analyzer's result consumer catches up.
    public func awaitIdle() async {
        guard worker != nil else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func run(lifecycle token: UUID) async {
        while isCurrent(token), requestedThrough > completedThrough {
            let target = requestedThrough
            do {
                try await finalize(target)
            } catch {
                guard isCurrent(token) else { return }
                // Fail once and retire rather than retrying the same broken
                // analyzer on every microphone packet.
                retired = true
                lifecycle = UUID()
                worker = nil
                finishWaiters()
                onFailure(error)
                return
            }
            guard isCurrent(token) else { return }
            completedThrough = max(completedThrough, target)
        }
        guard isCurrent(token) else { return }
        worker = nil
        finishWaiters()
    }

    private func isCurrent(_ token: UUID) -> Bool {
        !retired && lifecycle == token && !Task.isCancelled
    }

    private func finishWaiters() {
        let waiters = idleWaiters
        idleWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}
