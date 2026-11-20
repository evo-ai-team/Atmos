import AVFoundation
import CoreMedia
import Foundation
import Speech
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// Bridges the audio tap and the analyzer without sharing mutable PCM buffers.
/// Meter and stop state are lock-protected; one detached task owns conversion.
final class SpeechAudioFeed: @unchecked Sendable {
    private struct Capture: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let time: TimeInterval
        let containsSpeech: Bool
    }
    enum FeedError: LocalizedError {
        case allocation, overflow, conversion, formatChanged
        var errorDescription: String? {
            switch self {
            case .allocation: return "Atmos could not copy microphone audio. The unfinished command was discarded."
            case .overflow: return "Speech processing fell behind the microphone. The unfinished command was discarded."
            case .conversion: return "Atmos could not convert microphone audio for the speech model."
            case .formatChanged: return "The microphone format changed."
            }
        }
    }

    let inputSequence: AsyncThrowingStream<AnalyzerInput, Error>
    private let raw: AsyncThrowingStream<Capture, Error>.Continuation
    private let output: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private var conversionTask: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false
    private var speechThreshold = SpeechSensitivity.energyThreshold(for: SpeechSensitivity.defaultValue)
    private var rms = 0.0
    private var lastSpeechAt = ProcessInfo.processInfo.systemUptime
    private var lastBufferAt = ProcessInfo.processInfo.systemUptime

    init(
        inputFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        onPacket: @escaping @Sendable (SpeechAudioPacket) async -> Bool,
        onFailure: @escaping @Sendable (String) async -> Void
    ) throws {
        let rawPair = AsyncThrowingStream<Capture, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        let outputPair = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(256))
        raw = rawPair.continuation
        output = outputPair.continuation
        inputSequence = outputPair.stream
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else { throw FeedError.conversion }
        let output = outputPair.continuation
        conversionTask = Task.detached(priority: .userInitiated) {
            do {
                var framePosition: Int64 = 0
                for try await captured in rawPair.stream {
                    try Task.checkCancellation()
                    guard captured.buffer.format == inputFormat else { throw FeedError.formatChanged }
                    let converted = try Self.convert(captured.buffer, with: converter, to: targetFormat)
                    guard converted.frameLength > 0 else { continue }
                    let start = CMTime(value: framePosition, timescale: CMTimeScale(targetFormat.sampleRate))
                    let packet = SpeechAudioPacket(buffer: converted, start: start, capturedAt: captured.time, containsSpeech: captured.containsSpeech)
                    framePosition += Int64(converted.frameLength)
                    // Retain the packet before exposing it to recognition, so a
                    // result can never outrun the audio needed for its final pass.
                    guard await onPacket(packet) else { break }
                    try Task.checkCancellation()
                    switch output.yield(packet.input) {
                    case .enqueued: break
                    case .dropped: throw FeedError.overflow
                    case .terminated: return
                    @unknown default: throw FeedError.overflow
                    }
                }
                output.finish()
            } catch is CancellationError {
                output.finish()
            } catch {
                output.finish(throwing: error)
                await onFailure(error.localizedDescription)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let shouldStop = stopped
        lock.unlock()
        guard !shouldStop else { return }
        let copy: AVAudioPCMBuffer
        do {
            copy = try Self.ownedCopy(of: buffer)
        } catch {
            raw.finish(throwing: error)
            return
        }
        appendOwned(copy, capturedAt: ProcessInfo.processInfo.systemUptime)
    }

    /// The caller owns these samples. Network arrival time is unrelated to the
    /// instant they were spoken, so the original capture clock travels with PCM.
    func appendOwned(_ copy: AVAudioPCMBuffer, capturedAt now: TimeInterval) {
        let energy = Self.rootMeanSquare(of: copy)
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        rms = energy
        lastBufferAt = now
        // This only proposes an endpoint. Transcript activity also postpones
        // committing an utterance, and new sound invalidates its candidate.
        let containsSpeech = energy > speechThreshold
        if containsSpeech { lastSpeechAt = now }
        lock.unlock()
        switch raw.yield(Capture(buffer: copy, time: now, containsSpeech: containsSpeech)) {
        case .enqueued: break
        case .dropped: raw.finish(throwing: FeedError.overflow)
        case .terminated: break
        @unknown default: raw.finish(throwing: FeedError.overflow)
        }
    }

    func meter() -> (rms: Double, lastSpeechAt: TimeInterval, lastBufferAt: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        return (rms, lastSpeechAt, lastBufferAt)
    }

    /// Updating the activity gate never modifies the captured PCM samples.
    func setSensitivity(_ value: Double) {
        let threshold = SpeechSensitivity.energyThreshold(for: value)
        lock.lock()
        speechThreshold = threshold
        lock.unlock()
    }

    /// Finite diagnostics can close input and let conversion/output drain.
    func finishInput() {
        lock.lock(); stopped = true; lock.unlock()
        raw.finish()
    }

    func stop() {
        lock.lock(); stopped = true; lock.unlock()
        raw.finish()
        output.finish()
        conversionTask?.cancel()
        conversionTask = nil
    }

    /// The tap's buffer can be reused as soon as its callback returns. Copy all
    /// channels synchronously before any asynchronous consumer sees the capture.
    static func ownedCopy(of buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw FeedError.allocation
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { throw FeedError.conversion }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else {
                throw FeedError.conversion
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        return copy
    }

    private static func rootMeanSquare(of buffer: AVAudioPCMBuffer) -> Double {
        guard buffer.frameLength > 0 else { return 0 }
        var energy = 0.0
        if let channels = buffer.floatChannelData {
            for index in 0..<Int(buffer.frameLength) {
                energy += Double(channels[0][index] * channels[0][index])
            }
        } else if let channels = buffer.int16ChannelData {
            for index in 0..<Int(buffer.frameLength) {
                let sample = Double(channels[0][index]) / 32768
                energy += sample * sample
            }
        }
        return sqrt(energy / Double(buffer.frameLength))
    }

    static func convert(_ source: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if source.format == format { return source }
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw FeedError.allocation }
        var supplied = false
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return source
        }
        if let failure { throw failure }
        guard status != .error else { throw FeedError.conversion }
        return converted
    }
}
