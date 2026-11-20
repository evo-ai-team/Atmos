import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Local integration check: real Apple results, synthetic file input, production
/// audio feed, transcript assembly, wake state, finalizer, and boundary helper.
/// It never opens a microphone, calls OpenAI, or executes a computer action.
@main
struct LiveTranscriptCheck {
    struct Options {
        var fixtures = URL(fileURLWithPath: "Tools/Fixtures")
        var output = URL(fileURLWithPath: "live-transcript-results.json")
        var gaps = [0.25, 0.8, 1.5]
        var boundarySyncEnabled = true
        init() throws {
            var args = CommandLine.arguments.dropFirst().makeIterator()
            while let arg = args.next() {
                if arg == "--without-boundary-sync" { boundarySyncEnabled = false; continue }
                guard let value = args.next() else { throw CheckError.usage }
                switch arg {
                case "--fixtures": fixtures = URL(fileURLWithPath: value)
                case "--output": output = URL(fileURLWithPath: value)
                case "--gaps":
                    let fields = value.split(separator: ",")
                    let parsed = fields.compactMap { Double($0) }
                    guard !parsed.isEmpty, parsed.count == fields.count,
                          parsed.allSatisfy({ $0 >= 0.15 && $0 <= 5 }) else { throw CheckError.usage }
                    gaps = parsed
                default: throw CheckError.usage
                }
            }
        }
    }

    enum CheckError: LocalizedError {
        case usage, invalidFixture, format, recognition(String)
        var errorDescription: String? {
            switch self {
            case .usage: return "Usage: check-live-transcript.sh [--gaps 0.25,0.8,1.5] [--output results.json] [--without-boundary-sync]"
            case .invalidFixture: return "The bundled synthetic speech fixture is missing or invalid."
            case .format: return "Apple's transcriber has no compatible audio format."
            case .recognition(let message): return message
            }
        }
    }

    struct Run: Codable {
        var gap: Double
        var passed: Bool = false
        var wakeText = ""
        var liveWakeActivatedAt: Double?
        var wakeReplayFinishedAt: Double?
        var boundary: Double?
        var boundaryFinishedAt: Double?
        var firstCommandPreviewAt: Double?
        var commandSpeechEndsAt: Double
        var earlyPreviewDeadline: Double
        var visibleVolatileUpdates = 0
        var earlyGrowingUpdates = 0
        var failure: String?
        var events: [Event] = []
    }

    struct Event: Codable {
        let wall: Double
        let start: Double
        let end: Double
        let final: Bool
        let raw: String
        let assembled: String
        let visible: String
        let consumedThrough: Double
    }

    struct Report: Codable {
        let passed: Bool
        let fixture: String
        let engine: String
        let microphoneUsed: Bool
        let apiUsed: Bool
        let boundarySyncEnabled: Bool
        let runs: [Run]
    }

    @MainActor
    final class Observation {
        var transcript = SpeechTranscriptState()
        var session = WakeSession()
        var packets: [SpeechAudioPacket] = []
        var started = ProcessInfo.processInfo.systemUptime
        var wakeTask: Task<Void, Never>?
        var boundarySync: SpeechBoundarySynchronizer?
        var run: Run
        let locale: Locale
        let wakeEnd: Double
        var previousEarlyPreview = ""
        var visiblePreview = ""

        init(gap: Double, commandSpeechEndsAt: Double, locale: Locale, wakeEnd: Double) {
            run = Run(gap: gap, commandSpeechEndsAt: commandSpeechEndsAt, earlyPreviewDeadline: wakeEnd + gap + 3)
            self.locale = locale
            self.wakeEnd = wakeEnd
        }

        func packet(_ packet: SpeechAudioPacket) -> Bool {
            packets.append(packet)
            transcript.observeAudio(end: packet.endSeconds, lastSpeechAt: 0, convertedCaptureAt: packet.capturedAt)
            // The known fixture boundary isolates this check from microphone VAD.
            // Fast activation happens in receive(), before this accurate replay.
            // Intentionally withhold replay until live activation: this checks
            // that waking itself no longer depends on the accurate pass.
            if wakeTask == nil && session.isActive && packet.endSeconds >= wakeEnd + SpeechAudioHistoryPolicy.endpointSilence {
                let snapshot = packets.filter { $0.startSeconds < wakeEnd + SpeechAudioHistoryPolicy.endpointSilence }
                let boundary = snapshot.last!.endSeconds
                wakeTask = Task { @MainActor in
                    do {
                        let text = try await SpeechUtteranceFinalizer.transcribe(snapshot, locale: locale)
                        run.wakeReplayFinishedAt = elapsed
                        run.wakeText = text
                        session.beginRecognition(preservingPending: false)
                        _ = session.receive(text, at: now)
                        guard session.isActive else {
                            throw CheckError.recognition("The isolated wake pass did not recognize Hey Mouse: \(text)")
                        }
                        // Same strict consumption and engine synchronization as
                        // VoiceInput; no old text is admitted by relaxing its filter.
                        transcript.discard(through: boundary)
                        run.boundary = boundary
                        boundarySync?.request(through: boundary)
                        await boundarySync?.awaitIdle()
                        run.boundaryFinishedAt = elapsed
                        _ = session.finishUtterance(at: now)
                    } catch { run.failure = error.localizedDescription }
                }
            }
            return true
        }

        func receive(_ result: SpeechTranscriber.Result) {
            let start = result.range.start.seconds
            let end = CMTimeRangeGetEnd(result.range).seconds
            guard start.isFinite, end.isFinite else { return }
            var pieces: [SpeechTranscriptState.Segment] = []
            for item in result.text.runs {
                guard let range = item.audioTimeRange else { continue }
                let a = range.start.seconds
                let b = CMTimeRangeGetEnd(range).seconds
                guard a.isFinite, b.isFinite else { continue }
                pieces.append(.init(start: a, end: b,
                    text: String(result.text[item.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if pieces.isEmpty { pieces = [.init(start: start, end: end, text: String(result.text.characters))] }
            transcript.replace(start: start, end: end, with: pieces, at: now)
            let events = session.receive(transcript.text, at: now)
            for event in events {
                if event == .activated && run.liveWakeActivatedAt == nil { run.liveWakeActivatedAt = elapsed }
                if case .partial(let text) = event { visiblePreview = text }
            }
            let visible = visiblePreview
            if run.boundaryFinishedAt != nil && !result.isFinal && !visible.isEmpty {
                if run.firstCommandPreviewAt == nil { run.firstCommandPreviewAt = elapsed }
                run.visibleVolatileUpdates += 1
                if elapsed < run.earlyPreviewDeadline && visible.count > previousEarlyPreview.count {
                    run.earlyGrowingUpdates += 1
                    previousEarlyPreview = visible
                }
            }
            run.events.append(Event(wall: elapsed, start: start, end: end, final: result.isFinal,
                                    raw: String(result.text.characters), assembled: transcript.text,
                                    visible: visible, consumedThrough: transcript.consumedThrough))
        }

        var now: Double { ProcessInfo.processInfo.systemUptime }
        var elapsed: Double { now - started }
    }

    @MainActor static func main() async {
        do {
            let options = try Options()
            let fixture = options.fixtures.appendingPathComponent("mouse-command.wav")
            let locale = try await SpeechRuntimeSetup.supportedEnglishLocale()
            var runs: [Run] = []
            for gap in options.gaps {
                let result = try await check(fixture: fixture, gap: gap, locale: locale, boundarySyncEnabled: options.boundarySyncEnabled)
                runs.append(result)
                let latency = result.firstCommandPreviewAt.map { String(format: "%.3f s", $0) } ?? "none"
                print("\(result.passed ? "PASS" : "FAIL") gap=\(gap)s wake=\(result.wakeText) first preview=\(latency), \(result.earlyGrowingUpdates) growing provisional updates in the first 3 s of the command")
                if let failure = result.failure { print("  \(failure)") }
            }
            let report = Report(passed: runs.allSatisfy(\.passed), fixture: fixture.lastPathComponent,
                                engine: "Apple SpeechAnalyzer / SpeechTranscriber", microphoneUsed: false,
                                apiUsed: false, boundarySyncEnabled: options.boundarySyncEnabled, runs: runs)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: options.output, options: .atomic)
            print("Detailed results: \(options.output.path)")
            exit(report.passed ? 0 : 1)
        } catch {
            fputs("Live transcript check failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    @MainActor
    static func check(fixture: URL, gap: Double, locale: Locale, boundarySyncEnabled: Bool) async throws -> Run {
        // A diagnostic must fail instead of leaving a stalled model process
        // running indefinitely. Normal fixture playback takes about 10 seconds.
        let watchdog = Task {
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            fputs("Live transcript check timed out for gap \(gap)s.\n", stderr)
            exit(2)
        }
        defer { watchdog.cancel() }
        let file = try AVAudioFile(forReading: fixture)
        guard file.processingFormat.channelCount == 1,
              let original = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw CheckError.invalidFixture
        }
        try file.read(into: original)
        guard let originalSamples = original.floatChannelData?[0] else { throw CheckError.invalidFixture }
        let wakeEnd = 1.32
        let wakeFrames = Int((wakeEnd * file.processingFormat.sampleRate).rounded())
        let silenceFrames = Int((gap * file.processingFormat.sampleRate).rounded())
        guard Int(file.length) > wakeFrames else { throw CheckError.invalidFixture }
        var samples = Array(UnsafeBufferPointer(start: originalSamples, count: wakeFrames))
        samples += Array(repeating: Float(0), count: silenceFrames)
        samples += Array(UnsafeBufferPointer(start: originalSamples + wakeFrames, count: Int(file.length) - wakeFrames))
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        try await SpeechRuntimeSetup.ensureAssets(for: [module], locale: locale, allowsDownload: false)
        guard let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: file.processingFormat) else {
            throw CheckError.format
        }
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Hey Mouse", "Mouse"]
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: target)
        // The fixture's last spoken word ends at 8.76 seconds; trailing silence
        // is retained, but cannot count as evidence of live transcription.
        let state = Observation(gap: gap, commandSpeechEndsAt: 8.76 + gap,
                                locale: locale, wakeEnd: wakeEnd)
        if boundarySyncEnabled {
            state.boundarySync = SpeechBoundarySynchronizer(finalize: { through in
                try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: CMTimeScale(target.sampleRate.rounded())))
            }, onFailure: { [weak state] error in state?.run.failure = error.localizedDescription })
        }
        let feed = try SpeechAudioFeed(inputFormat: file.processingFormat, targetFormat: target,
            onPacket: { await state.packet($0) }, onFailure: { message in await MainActor.run { state.run.failure = message } })
        defer { feed.stop() }
        defer { state.boundarySync?.cancel() }
        let results = Task { @MainActor in
            for try await result in module.results { state.receive(result) }
        }
        try await analyzer.start(inputSequence: feed.inputSequence)
        state.started = ProcessInfo.processInfo.systemUptime
        do {
            var position = 0
            while position < samples.count {
                var count = min(1024, samples.count - position)
                if position < wakeFrames { count = min(count, wakeFrames - position) }
                guard let chunk = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                      let output = chunk.floatChannelData?[0] else { throw CheckError.invalidFixture }
                chunk.frameLength = AVAudioFrameCount(count)
                samples.withUnsafeBufferPointer { output.update(from: $0.baseAddress! + position, count: count) }
                feed.append(chunk)
                position += count
                let wait = Double(position) / file.processingFormat.sampleRate - state.elapsed
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
            }
            feed.finishInput()
            await state.wakeTask?.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
            try await results.value
        } catch {
            results.cancel()
            state.wakeTask?.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
        if state.run.failure == nil {
            if let activated = state.run.liveWakeActivatedAt, let replay = state.run.wakeReplayFinishedAt, activated >= replay {
                state.run.failure = "Live wake activation did not precede the accurate replay."
            } else if state.run.liveWakeActivatedAt == nil {
                state.run.failure = "The live recognizer never activated Mouse before replay."
            } else if let first = state.run.firstCommandPreviewAt, first < state.run.earlyPreviewDeadline,
               state.run.earlyGrowingUpdates >= 2 {
                state.run.passed = true
            } else {
                state.run.failure = "Fewer than two growing provisional previews appeared during the first three seconds of the command."
            }
        }
        return state.run
    }
}
