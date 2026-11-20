import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Buffers are owned copies and are immutable after entering either stream.
/// `start` locates samples in analyzer time; `capturedAt` uses system uptime so
/// the endpoint can detect conversion backlog independently of sample positions.
struct SpeechAudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let start: CMTime
    let capturedAt: TimeInterval
    let containsSpeech: Bool
    init(buffer: AVAudioPCMBuffer, start: CMTime, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime, containsSpeech: Bool = false) {
        self.buffer = buffer
        self.start = start
        self.capturedAt = capturedAt
        self.containsSpeech = containsSpeech
    }
    var startSeconds: Double { CMTimeGetSeconds(start) }
    var endSeconds: Double { startSeconds + Double(buffer.frameLength) / buffer.format.sampleRate }
    var input: AnalyzerInput { AnalyzerInput(buffer: buffer, bufferStartTime: start) }
}

