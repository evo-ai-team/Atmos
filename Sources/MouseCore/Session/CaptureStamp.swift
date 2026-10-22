import Foundation

/// A speculative capture is usable only by the exact utterance and task generation
/// that started it. Time is monotonic, and coordinates are validated separately.
public struct CaptureStamp: Sendable {
    public let utteranceID: UUID
    public let generation: UUID
    public let processID: Int32
    public let capturedAt: TimeInterval
    public init(utteranceID: UUID, generation: UUID, processID: Int32, capturedAt: TimeInterval) {
        self.utteranceID = utteranceID
        self.generation = generation
        self.processID = processID
        self.capturedAt = capturedAt
    }
    public func canReuse(utteranceID: UUID, generation: UUID, processID: Int32, now: TimeInterval) -> Bool {
        let age = now - capturedAt
        return self.utteranceID == utteranceID && self.generation == generation
            && self.processID == processID && capturedAt.isFinite && now.isFinite
            && age >= 0 && age <= 1.5
    }
}
