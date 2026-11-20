import Foundation

/// The capture tap and WebSocket can deliver different chunk sizes. Retain
/// partial PCM until a complete 30 ms frame can be passed to the next stage.
struct KrispPCMFramer {
    private var pending = Data()
    var pendingByteCount: Int { pending.count }

    mutating func append(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        let size = KrispVoiceIsolationSession.frameBytes
        var offset = pending.startIndex
        var frames = [Data]()
        while pending.endIndex - offset >= size {
            frames.append(pending.subdata(in: offset..<(offset + size)))
            offset += size
        }
        if offset != pending.startIndex {
            pending = Data(pending[offset...])
        }
        return frames
    }
}
