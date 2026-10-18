import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Buffers are owned copies and are immutable after entering either stream.
struct SpeechAudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let start: CMTime
    let capturedAt: TimeInterval
    init(buffer: AVAudioPCMBuffer, start: CMTime, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.buffer = buffer; self.start = start; self.capturedAt = capturedAt
    }
    var startSeconds: Double { CMTimeGetSeconds(start) }
    var endSeconds: Double { startSeconds + Double(buffer.frameLength) / buffer.format.sampleRate }
    var input: AnalyzerInput { AnalyzerInput(buffer: buffer, bufferStartTime: start) }
}

final class SpeechAudioFeed: @unchecked Sendable {
    private struct Capture: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        let time: TimeInterval
    }
    enum FeedError: LocalizedError {
        case allocation, overflow, conversion, formatChanged
        var errorDescription: String? {
            switch self {
            case .allocation: return "Mouse could not copy microphone audio. Voice was paused before any incomplete command was submitted."
            case .overflow: return "Speech processing fell behind the microphone. Voice was paused; please enable it and repeat the command."
            case .conversion: return "Mouse could not convert microphone audio for the speech model."
            case .formatChanged: return "The microphone format changed. Enable the microphone again to resume voice control."
            }
        }
    }

    let inputSequence: AsyncThrowingStream<AnalyzerInput, Error>
    private let raw: AsyncThrowingStream<Capture, Error>.Continuation
    private let output: AsyncThrowingStream<AnalyzerInput, Error>.Continuation
    private var conversionTask: Task<Void, Never>?
    private let lock = NSLock()
    private var stopped = false
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
                    let packet = SpeechAudioPacket(buffer: converted, start: start, capturedAt: captured.time)
                    framePosition += Int64(converted.frameLength)
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
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            raw.finish(throwing: FeedError.allocation); return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else { raw.finish(throwing: FeedError.conversion); return }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else {
                raw.finish(throwing: FeedError.conversion); return
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
        }
        var energy = 0.0
        if let channels = copy.floatChannelData, copy.frameLength > 0 {
            for index in 0..<Int(copy.frameLength) { energy += Double(channels[0][index] * channels[0][index]) }
            energy = sqrt(energy / Double(copy.frameLength))
        }
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        rms = energy
        lastBufferAt = now
        // This only proposes an endpoint; it can never submit provisional text.
        // Transcript activity also postpones finalization, and new sound invalidates it.
        if energy > 0.006 { lastSpeechAt = now }
        lock.unlock()
        switch raw.yield(Capture(buffer: copy, time: now)) {
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

    private static func convert(_ source: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
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

/// A completed final-only results stream is the submission barrier. The live
/// analyzer and microphone continue independently while this short local pass runs.
enum SpeechUtteranceFinalizer {
    static func transcribe(_ packets: [SpeechAudioPacket], locale: Locale) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Hey Mouse", "Mouse"]
        try await analyzer.setContext(context)
        let results = Task {
            var text: [String] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                text.append(String(result.text.characters))
            }
            return text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await withTaskCancellationHandler {
            do {
                let sequence = AsyncStream<AnalyzerInput> { continuation in
                    for packet in packets { continuation.yield(packet.input) }
                    continuation.finish()
                }
                if let lastSample = try await analyzer.analyzeSequence(sequence) {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                let text = try await results.value
                try Task.checkCancellation()
                return text
            } catch {
                results.cancel()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
