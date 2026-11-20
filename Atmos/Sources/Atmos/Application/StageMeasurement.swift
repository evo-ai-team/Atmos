import Foundation
#if SWIFT_PACKAGE
import AtmosCore
#endif

extension AppModel {
    /// Keep stage boundaries beside the work they measure. These wrappers leave
    /// errors and cancellation intact and never write telemetry to disk.
    func measureStage<Value>(_ timing: PipelineTiming?, _ name: String,
                             operation: () throws -> Value) rethrows -> Value {
        let span = timing?.begin(name)
        do {
            let value = try operation()
            timing?.end(span)
            return value
        } catch {
            timing?.end(span, outcome: error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            throw error
        }
    }

    func measureStage<Value>(_ timing: PipelineTiming?, _ name: String,
                             operation: () async throws -> Value) async rethrows -> Value {
        let span = timing?.begin(name)
        do {
            let value = try await operation()
            timing?.end(span, outcome: Task.isCancelled ? .cancelled : .succeeded)
            return value
        } catch {
            timing?.end(span, outcome: error is CancellationError || Task.isCancelled ? .cancelled : .failed)
            throw error
        }
    }
}
