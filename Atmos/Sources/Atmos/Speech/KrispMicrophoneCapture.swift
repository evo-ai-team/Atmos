import AVFoundation
import Foundation

private struct CapturedMicrophoneAudio: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let end: TimeInterval
    var start: TimeInterval { end - Double(buffer.frameLength) / buffer.format.sampleRate }

    func after(_ boundary: TimeInterval) throws -> CapturedMicrophoneAudio? {
        guard end > boundary else { return nil }
        guard start < boundary else { return self }
        let drop = min(Int(buffer.frameLength), Int(ceil((boundary - start) * buffer.format.sampleRate)))
        guard drop < Int(buffer.frameLength) else { return nil }
        let remaining = buffer.frameLength - AVAudioFrameCount(drop)
        guard let suffix = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: remaining) else {
            throw SpeechAudioFeed.FeedError.allocation
        }
        suffix.frameLength = remaining
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let output = UnsafeMutableAudioBufferListPointer(suffix.mutableAudioBufferList)
        for i in source.indices {
            let bytesPerFrame = Int(source[i].mDataByteSize) / Int(buffer.frameLength)
            guard let src = source[i].mData, let dst = output[i].mData else { throw SpeechAudioFeed.FeedError.conversion }
            memcpy(dst, src.advanced(by: drop * bytesPerFrame), Int(remaining) * bytesPerFrame)
        }
        return CapturedMicrophoneAudio(buffer: suffix, end: end)
    }
}

/// Owns the tap for one engine lifetime. The short wake buffer stays on this
/// Mac until a local wake decision names the start of an utterance.
final class KrispMicrophoneCapture: @unchecked Sendable {
    enum Failure: LocalizedError {
        case missingKey, missingWakeAudio, unverifiedWake, backlog, unexpectedOutput, stalled
        var errorDescription: String? {
            switch self {
            case .missingKey: return "Krisp VIVA Pro needs a key. Save or reconnect your Krisp API key in Settings."
            case .missingWakeAudio: return "The beginning of the wake phrase is unavailable. Please wake the assistant again."
            case .unverifiedWake: return "VIVA Pro could not confirm the complete wake phrase. The unfinished command was discarded."
            case .backlog: return "Krisp VIVA Pro fell behind the microphone. The unfinished command was discarded."
            case .unexpectedOutput: return "Krisp VIVA Pro returned audio that could not be matched to the microphone."
            case .stalled: return "Krisp VIVA Pro stopped returning audio. Check your connection and wake the assistant again."
            }
        }
    }

    private let lock = NSLock()
    private var standby: SpeechAudioFeed?
    private var active: KrispMicrophoneStream?
    private var activeFrom: TimeInterval = 0
    private var wakeHistory: [CapturedMicrophoneAudio] = []
    private var lastCapture = ProcessInfo.processInfo.systemUptime
    private let fail: @Sendable (String) -> Void

    init(standby: SpeechAudioFeed, fail: @escaping @Sendable (String) -> Void) {
        self.standby = standby
        self.fail = fail
    }

    func append(_ buffer: AVAudioPCMBuffer, at timestamp: AVAudioTime? = nil) {
        let end: TimeInterval
        if let timestamp, timestamp.isHostTimeValid {
            end = AVAudioTime.seconds(forHostTime: timestamp.hostTime) + Double(buffer.frameLength) / buffer.format.sampleRate
        } else {
            end = ProcessInfo.processInfo.systemUptime
        }
        do {
            let capture = CapturedMicrophoneAudio(buffer: try SpeechAudioFeed.ownedCopy(of: buffer), end: end)
            lock.lock()
            defer { lock.unlock() }
            lastCapture = end
            if let active {
                if let allowed = try capture.after(activeFrom) { active.enqueue(allowed) }
            } else if let standby {
                wakeHistory.append(capture)
                if let first = wakeHistory.first, end - first.end > 8 {
                    wakeHistory.removeAll { end - $0.end > 8 }
                }
                standby.appendOwned(capture.buffer, capturedAt: end)
            }
        } catch { fail(error.localizedDescription) }
    }

    func lastCaptureTime() -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return lastCapture
    }

    func begin(_ stream: KrispMicrophoneStream, from start: TimeInterval, requireWake: Bool) throws {
        lock.lock(); defer { lock.unlock() }
        guard standby != nil, active == nil else { throw CancellationError() }
        if requireWake, wakeHistory.first.map({ $0.start > start + 0.05 }) ?? true {
            throw Failure.missingWakeAudio
        }
        // Preserve order while the tap switches destinations. Include only the
        // recognized wake/command interval; a manual activation has no pre-roll.
        for capture in wakeHistory where capture.end > start {
            if let allowed = try capture.after(start) { stream.enqueue(allowed) }
        }
        wakeHistory.removeAll()
        standby = nil
        activeFrom = start
        active = stream
    }

    func stop() {
        lock.lock()
        standby = nil
        let stream = active
        active = nil
        wakeHistory.removeAll()
        lock.unlock()
        stream?.stop()
    }
}

/// One full-duplex socket per active voice session. Only its sender uses the
/// hardware converter. Output is paired by PCM sample count with the original
/// capture timestamps, independently of WebSocket message sizes or timing.
final class KrispMicrophoneStream: @unchecked Sendable {
    static let wireFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
        sampleRate: Double(KrispVoiceIsolationSession.sampleRate), channels: 1, interleaved: false)!

    private let raw: AsyncThrowingStream<CapturedMicrophoneAudio, Error>.Continuation
    private let socket: KrispVoiceIsolationSession
    private let task: Task<Void, Never>

    init(apiKey: String, inputFormat: AVAudioFormat, output: SpeechAudioFeed,
         onFailure: @escaping @Sendable (String) async -> Void) throws {
        let format = Self.wireFormat
        guard let converter = AVAudioConverter(from: inputFormat, to: format) else {
            throw SpeechAudioFeed.FeedError.conversion
        }
        let input = AsyncThrowingStream<CapturedMicrophoneAudio, Error>.makeStream(bufferingPolicy: .bufferingOldest(1024))
        raw = input.continuation
        let socket = KrispVoiceIsolationSession(apiKey: apiKey)
        self.socket = socket
        let timestamps = KrispFrameTimes()
        task = Task.detached(priority: .userInitiated) {
            defer { socket.close() }
            do {
                try await socket.connect()
                try Task.checkCancellation()
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        var framer = KrispPCMFramer()
                        for try await capture in input.stream {
                            try Task.checkCancellation()
                            guard capture.buffer.format == inputFormat else { throw SpeechAudioFeed.FeedError.formatChanged }
                            let pcm = try SpeechAudioFeed.convert(capture.buffer, with: converter, to: format)
                            guard pcm.frameLength > 0, let samples = pcm.int16ChannelData?[0] else { continue }
                            let frames = framer.append(Data(bytes: samples, count: Int(pcm.frameLength) * 2))
                            let bufferedTail = Double(framer.pendingByteCount / 2) / format.sampleRate
                            let duration = Double(KrispVoiceIsolationSession.frameSamples) / format.sampleRate
                            for (index, frame) in frames.enumerated() {
                                let end = capture.end - bufferedTail - Double(frames.count - index - 1) * duration
                                try await timestamps.record(end)
                                try await socket.send(frame)
                            }
                        }
                    }
                    group.addTask {
                        var framer = KrispPCMFramer()
                        while !Task.isCancelled {
                            let message = try await socket.receive()
                            try Task.checkCancellation()
                            for frame in framer.append(message) {
                                let end = try await timestamps.consume()
                                guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                    frameCapacity: AVAudioFrameCount(KrispVoiceIsolationSession.frameSamples)),
                                      let samples = buffer.int16ChannelData?[0] else { throw SpeechAudioFeed.FeedError.allocation }
                                buffer.frameLength = buffer.frameCapacity
                                frame.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: frame.count))
                                output.appendOwned(buffer, capturedAt: end)
                            }
                        }
                    }
                    // Closing the socket and capture stream unblocks both children,
                    // including the one currently waiting for the next microphone buffer.
                    defer { group.cancelAll(); socket.close(); input.continuation.finish() }
                    _ = try await group.next()
                }
            } catch {
                if !Task.isCancelled { await onFailure(error.localizedDescription) }
            }
        }
    }

    fileprivate func enqueue(_ capture: CapturedMicrophoneAudio) {
        if case .dropped = raw.yield(capture) { raw.finish(throwing: KrispMicrophoneCapture.Failure.backlog) }
    }

    func stop() {
        task.cancel()
        socket.close()
        raw.finish()
    }
}

private actor KrispFrameTimes {
    private var pending: [TimeInterval] = []
    func record(_ end: TimeInterval) throws {
        guard pending.count < 512 else { throw KrispMicrophoneCapture.Failure.backlog }
        pending.append(end)
    }
    func consume() throws -> TimeInterval {
        guard !pending.isEmpty else { throw KrispMicrophoneCapture.Failure.unexpectedOutput }
        return pending.removeFirst()
    }
}
