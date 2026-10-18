import AVFoundation
import CoreMedia
import Foundation
import Speech
#if SWIFT_PACKAGE
import ChosenCore
#endif

@MainActor
final class VoiceInput {
    var onCommand: ((String) -> Void)?
    var onPartial: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onStatus: ((String) -> Void)?
    var onActivationChanged: ((Bool) -> Void)?
    var onDeactivation: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var isActive: Bool { session.isActive }
    private(set) var isRunning = false

    enum InputError: LocalizedError {
        case microphoneDenied, noMicrophone, missingUsageDescription, formatUnavailable
        case microphoneChanged, audioStalled, utteranceTooLong, unavailableAudio, finalizationTimedOut
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Allow Mouse microphone access in System Settings → Privacy & Security."
            case .noMicrophone: return "No microphone is available. Connect one, then enable the microphone again."
            case .missingUsageDescription: return "Launch the packaged Mouse app to enable microphone permissions."
            case .formatUnavailable: return "Apple's speech model has no compatible audio format on this Mac."
            case .microphoneChanged: return "The microphone changed. Enable it again in Mouse and repeat the unfinished command."
            case .audioStalled: return "The microphone stopped providing audio. Enable it again to resume voice control."
            case .utteranceTooLong: return "Voice paused because the unfinished utterance exceeded one minute. Enable the microphone and use a shorter command."
            case .unavailableAudio: return "Speech recognition fell behind the audio buffer. Enable the microphone and repeat the command."
            case .finalizationTimedOut: return "The speech model could not finalize this utterance. Voice was paused without submitting unfinished text."
            }
        }
    }

    private var session = WakeSession()
    private var transcript = SpeechTranscriptState()
    private var history: [SpeechAudioPacket] = []
    private var snapshotFloor: TimeInterval = 0
    private var resetCaptureFloor: TimeInterval = 0
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var feed: SpeechAudioFeed?
    private var analyzer: SpeechAnalyzer?
    private var locale: Locale?
    private var configurationObserver: NSObjectProtocol?
    private var startupTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var finalTaskID: UUID?
    private var lifecycle = UUID()
    private var isStarting = false
    private var executionInProgress = false
    private var presentedActive = false
    private var publishedPartial = ""
    private var lastLevel = 0.0

    func start() async throws {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        let startID = UUID()
        lifecycle = startID
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.prepare(startID: startID)
        }
        // Keep an owned task so Pause Microphone cancels an asset download too.
        startupTask = task
        defer { isStarting = false; startupTask = nil }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if lifecycle == startID { stop() }
            throw error
        }
    }

    private func prepare(startID: UUID) async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { throw InputError.missingUsageDescription }
        guard await Self.microphoneAuthorization() else { throw InputError.microphoneDenied }
        try ensureCurrent(startID)
        onStatus?("Preparing Apple's speech transcriber…")
        let selectedLocale = try await SpeechRuntimeSetup.supportedEnglishLocale()
        let transcriber = SpeechTranscriber(locale: selectedLocale, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange])
        try await SpeechRuntimeSetup.ensureAssets(for: [transcriber], locale: selectedLocale, allowsDownload: true) { [weak self] status in
            guard let self, self.lifecycle == startID else { return }
            self.onStatus?(status)
        }
        try ensureCurrent(startID)
        let engine = AVAudioEngine()
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else { throw InputError.noMicrophone }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat) else { throw InputError.formatUnavailable }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Hey Mouse", "Hey Chosen", "Mouse", "Chosen"]
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        try ensureCurrent(startID)

        session = WakeSession()
        session.setExecuting(executionInProgress, at: Self.now)
        transcript = SpeechTranscriptState()
        history = []
        snapshotFloor = 0
        resetCaptureFloor = 0
        self.locale = selectedLocale
        self.analyzer = analyzer
        self.engine = engine
        let feed = try SpeechAudioFeed(inputFormat: naturalFormat, targetFormat: format) { [weak self] packet in
            await self?.receiveAudio(packet, lifecycle: startID) ?? false
        } onFailure: { [weak self] message in
            await self?.fail(message, lifecycle: startID)
        }
        self.feed = feed
        isRunning = true
        presentActivation(false)
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.isRunning, self.lifecycle == startID, !Task.isCancelled else { return }
                    self.receive(result)
                }
                if let self, self.isRunning, self.lifecycle == startID, !Task.isCancelled {
                    self.fail("Apple's live speech stream ended unexpectedly. Enable the microphone again.", lifecycle: startID)
                }
            } catch is CancellationError {} catch {
                self?.fail(error.localizedDescription, lifecycle: startID)
            }
        }
        try await analyzer.start(inputSequence: feed.inputSequence)
        try ensureCurrent(startID)
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: naturalFormat) { buffer, _ in feed.append(buffer) }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fail(InputError.microphoneChanged.localizedDescription, lifecycle: startID) }
        }
        startTimer(lifecycle: startID)
        onStatus?(executionInProgress ? "Working · say “stop” to sleep" : "Say “Hey Mouse”")
    }

    func stop() {
        lifecycle = UUID()
        isRunning = false
        startupTask?.cancel()
        timerTask?.cancel(); timerTask = nil
        resultsTask?.cancel(); resultsTask = nil
        cancelFinalPass()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
        }
        tapInstalled = false
        engine = nil
        feed?.stop(); feed = nil
        if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
        analyzer = nil
        locale = nil
        history = []
        snapshotFloor = 0
        resetCaptureFloor = 0
        transcript = SpeechTranscriptState()
        session = WakeSession()
        presentActivation(false)
        lastLevel = 0
        onLevel?(0)
        publishPartial("")
        onStatus?("Microphone off")
    }

    func activate() {
        guard isRunning, !session.isExecuting else { return }
        resetUtterance()
        handle(session.activate(at: Self.now))
    }

    func deactivate() {
        resetUtterance()
        handle(session.deactivate())
    }

    func setExecuting(_ executing: Bool) {
        let changed = executionInProgress != executing
        executionInProgress = executing
        // A stop already being spoken survives task completion; other busy audio
        // must not become a fresh idle command.
        if changed, VoiceControl.match(transcript.text) == nil { resetUtterance() }
        session.setExecuting(executing, at: Self.now)
        guard isRunning else { return }
        onStatus?(executing ? "Working · say “stop” to sleep" : session.isActive ? "Listening…" : "Say “Hey Mouse”")
    }

    private func receiveAudio(_ packet: SpeechAudioPacket, lifecycle id: UUID) -> Bool {
        guard isRunning, lifecycle == id else { return false }
        let meter = feed?.meter()
        if transcript.observeAudio(end: packet.endSeconds, lastSpeechAt: meter?.lastSpeechAt ?? Self.now, convertedCaptureAt: packet.capturedAt) { cancelFinalPass() }
        // A reset also excludes audio captured earlier but still awaiting conversion,
        // and drops a single packet straddling the boundary rather than replaying it.
        if packet.capturedAt - (packet.endSeconds - packet.startSeconds) < resetCaptureFloor {
            snapshotFloor = packet.endSeconds
            transcript.discard(through: packet.endSeconds)
            trimHistory()
            return true
        }
        history.append(packet)
        trimHistory()
        if let first = history.first, packet.endSeconds - first.startSeconds > 65 || history.count > 4_096 {
            fail(InputError.utteranceTooLong.localizedDescription, lifecycle: id)
            return false
        }
        return true
    }

    private func receive(_ result: SpeechTranscriber.Result) {
        let start = CMTimeGetSeconds(result.range.start)
        let end = CMTimeGetSeconds(CMTimeRangeGetEnd(result.range))
        var pieces: [SpeechTranscriptState.Segment] = []
        for run in result.text.runs {
            guard let range = run.audioTimeRange else { continue }
            let a = CMTimeGetSeconds(range.start)
            let b = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard a.isFinite, b.isFinite else { continue }
            pieces.append(.init(start: a, end: b, text: String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        if pieces.isEmpty { pieces = [.init(start: start, end: end, text: String(result.text.characters))] }
        if transcript.replace(start: start, end: end, with: pieces, at: Self.now) { cancelFinalPass() }
        publishPreview()
    }

    private func publishPreview() {
        // Volatile recognition can suggest a wake phrase, but only corrected
        // final text changes the authoritative WakeSession activation state.
        var preview = session
        preview.beginRecognition(preservingPending: false)
        let events = preview.receive(transcript.text, at: Self.now)
        presentActivation(preview.isActive)
        let partial = events.compactMap { event -> String? in
            if case .partial(let text) = event { return text }
            return nil
        }.last ?? ""
        publishPartial(partial)
    }

    private func startTimer(lifecycle id: UUID) {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.isRunning, self.lifecycle == id else { return }
                self.tick(lifecycle: id)
            }
        }
    }

    private func tick(lifecycle id: UUID) {
        guard let feed else { return }
        let now = Self.now
        let meter = feed.meter()
        lastLevel = lastLevel * 0.65 + min(1, meter.rms * 14) * 0.35
        onLevel?(lastLevel)
        if now - meter.lastBufferAt > 3 { fail(InputError.audioStalled.localizedDescription, lifecycle: id); return }
        if transcript.observeAudio(end: transcript.audioEnd, lastSpeechAt: meter.lastSpeechAt) { cancelFinalPass() }
        guard finalTask == nil, let candidate = transcript.beginFinalization(at: now, silenceDuration: 1.0, latestCaptureAt: meter.lastBufferAt) else { return }
        var preview = session
        preview.beginRecognition(preservingPending: false)
        _ = preview.receive(transcript.text, at: now)
        if !session.isActive && !session.isExecuting && !preview.isActive {
            _ = transcript.commit(candidate)
            trimHistory()
            return
        }
        guard let locale, let first = history.first,
              transcript.firstTextStart.map({ $0 + 0.05 >= first.startSeconds }) ?? false else {
            fail(InputError.unavailableAudio.localizedDescription, lifecycle: id); return
        }
        // Keep real leading context and the full observed trailing silence.
        let from = max(snapshotFloor, transcript.consumedThrough - 0.6)
        let packets = history.filter { $0.startSeconds >= snapshotFloor && $0.endSeconds > from && $0.startSeconds < candidate.through }
        guard !packets.isEmpty else { fail(InputError.unavailableAudio.localizedDescription, lifecycle: id); return }
        finalTaskID = candidate.id
        finalTask = Task { @MainActor [weak self] in
            do {
                let finalText = try await withThrowingTaskGroup(of: String.self) { group in
                    group.addTask { try await SpeechUtteranceFinalizer.transcribe(packets, locale: locale) }
                    group.addTask {
                        try await Task.sleep(for: .seconds(12))
                        throw InputError.finalizationTimedOut
                    }
                    defer { group.cancelAll() }
                    return try await group.next() ?? ""
                }
                guard let self, self.isRunning, self.lifecycle == id, !Task.isCancelled else { return }
                guard let meter = self.feed?.meter() else { self.cancelFinalPass(); return }
                if self.transcript.observeAudio(end: self.transcript.audioEnd, lastSpeechAt: meter.lastSpeechAt)
                    || !self.transcript.audioIsCaughtUp(at: Self.now, latestCaptureAt: meter.lastBufferAt) {
                    self.cancelFinalPass(); return
                }
                guard self.transcript.commit(candidate) else { self.cancelFinalPass(); return }
                self.finalTask = nil; self.finalTaskID = nil
                self.trimHistory()
                // Reset text assembly only, preserving persistent activation.
                // Re-read the corrected full phrase so a revised wake word cannot
                // accidentally authorize an utterance heard while on standby.
                self.session.beginRecognition(preservingPending: false)
                self.handle(self.session.receive(finalText, at: Self.now))
                self.presentActivation(self.session.isActive)
                self.handle(self.session.finishUtterance(at: Self.now))
                if !self.session.isExecuting { self.publishPartial("") }
            } catch is CancellationError {
            } catch {
                guard let self, self.lifecycle == id, self.transcript.isCurrent(candidate) else { return }
                self.fail(error.localizedDescription, lifecycle: id)
            }
            if let self, self.finalTaskID == candidate.id { self.finalTask = nil; self.finalTaskID = nil }
        }
    }

    private func handle(_ events: [WakeSession.Event]) {
        for event in events {
            switch event {
            case .activated:
                presentActivation(true)
                onStatus?("Listening…")
            case .partial(let text): publishPartial(text)
            case .command(let text):
                publishedPartial = ""
                onCommand?(text)
            case .ignored: publishPartial("")
            case .deactivated:
                executionInProgress = false
                presentActivation(false)
                publishPartial("")
                onDeactivation?()
                onStatus?(isRunning ? "Say “Hey Mouse”" : "Microphone off")
            }
        }
    }

    private func resetUtterance() {
        cancelFinalPass()
        snapshotFloor = transcript.audioEnd
        resetCaptureFloor = Self.now
        transcript.discard(through: transcript.audioEnd)
        session.beginRecognition(preservingPending: false)
        trimHistory()
        publishPartial("")
    }

    private func trimHistory() {
        let keepFrom = transcript.text.isEmpty && transcript.candidate == nil
            ? max(transcript.consumedThrough - 0.6, transcript.audioEnd - 8)
            : max(0, transcript.consumedThrough - 0.6)
        history.removeAll { $0.startSeconds < snapshotFloor || $0.endSeconds <= keepFrom }
    }

    private func cancelFinalPass() {
        finalTask?.cancel(); finalTask = nil; finalTaskID = nil
        transcript.invalidateFinalization()
    }

    private func publishPartial(_ text: String) {
        guard text != publishedPartial else { return }
        publishedPartial = text
        onPartial?(text)
    }

    private func presentActivation(_ active: Bool) {
        guard active != presentedActive else { return }
        presentedActive = active
        onActivationChanged?(active)
    }

    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle == id else { throw CancellationError() }
    }

    private func fail(_ message: String, lifecycle id: UUID) {
        guard lifecycle == id else { return }
        stop()
        onFailure?(message)
        onStatus?(message)
    }

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func microphoneAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }
}
