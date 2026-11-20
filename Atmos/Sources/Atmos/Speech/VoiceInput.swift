import AVFoundation
import CoreMedia
import Foundation
import Speech
#if SWIFT_PACKAGE
import AtmosCore
#endif

@MainActor
final class VoiceInput {
    enum Purpose { case commands, menuDictation }
    private let purpose: Purpose
    var onDictatedUtterance: ((String) -> Void)?
    var onMicrophonePermissionPrompt: ((Bool) -> Void)?
    var onCommand: ((String) -> Void)?
    var onTimingStarted: ((UUID, PipelineTiming) -> Void)?
    var onFinalizationStarted: ((UUID) -> Void)?
    var onFinalizationInvalidated: ((UUID) -> Void)?
    var onFinalizedCommand: ((String, UUID) -> Void)?
    var onPartial: ((String) -> Void)?
    var onLevel: ((Double) -> Void)?
    var onStatus: ((String) -> Void)?
    var onActivationChanged: ((Bool) -> Void)?
    var onDeactivation: (() -> Void)?
    var onFailure: ((String) -> Void)?
    /// Changes the speech-activity threshold only; 50% preserves the old gate.
    var audioSensitivity: Double {
        get { sensitivity }
        set {
            sensitivity = SpeechSensitivity.normalized(newValue)
            feed?.setSensitivity(sensitivity)
        }
    }
    /// Read at the next endpoint. Changing this never cancels an ongoing replay.
    var secondPassEnabled = true
    var isEnabled: Bool { recovery.isEnabled }
    /// Includes raw audio that has not yet reached the timer/recognizer.
    /// Activity alone is not permission to interrupt the current computer task.
    var hasUncommittedSpeech: Bool {
        guard isRunning, session.isActive else { return false }
        return !transcript.text.isEmpty || finalTask != nil
            || activityGate.hasUnconsumedSpeech(lastSpeechAt: feed?.meter().lastSpeechAt ?? 0)
    }
    private(set) var isRunning = false

    enum InputError: LocalizedError {
        case microphoneDenied, noMicrophone, missingUsageDescription, formatUnavailable
        case microphoneChanged, audioStalled, utteranceTooLong, unavailableAudio, incompleteReplay, finalizationTimedOut
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Allow Atmos microphone access in System Settings → Privacy & Security."
            case .noMicrophone: return "No microphone is available. Connect one, then enable the microphone again."
            case .missingUsageDescription: return "Launch the packaged Atmos app to enable microphone permissions."
            case .formatUnavailable: return "Apple's speech model has no compatible audio format on this Mac."
            case .microphoneChanged: return "The microphone changed. The unfinished command was discarded."
            case .audioStalled: return "The microphone stopped providing audio."
            case .utteranceTooLong: return "The unfinished utterance exceeded one minute and was discarded."
            case .unavailableAudio: return "Audio for the unfinished command is unavailable."
            case .incompleteReplay: return "Atmos could not verify the beginning of that command. Please repeat the full command."
            case .finalizationTimedOut: return "The speech model could not finalize this utterance. The unfinished text was discarded."
            }
        }
    }

    private var session = WakeSession()
    private var sensitivity = SpeechSensitivity.defaultValue
    private var transcript = SpeechTranscriptState()
    private var history: [SpeechAudioPacket] = []
    private var snapshotFloor: TimeInterval = 0
    private var resetCaptureFloor: TimeInterval = 0
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var feed: SpeechAudioFeed?
    private var capture: KrispMicrophoneCapture?
    private var krispEnabled = false
    private var krispKey = ""
    private var isolationStartedAt: TimeInterval?
    private var isolatedEndpoint = IsolatedSpeechEndpoint()
    private var wakeWindow = WakeAudioWindow()
    private var verifyingWake = false
    private var heardCleanWake = false
    private var isolationSetup: Task<Void, Never>?
    private var recognitionID = UUID()
    private var recognitionFormat: AVAudioFormat?
    private var captureFormat: AVAudioFormat?
    private var analyzer: SpeechAnalyzer?
    private var liveBoundary: SpeechBoundarySynchronizer?
    private var locale: Locale?
    private var configurationObserver: NSObjectProtocol?
    private var startupTask: Task<Void, Error>?
    private var resultsTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var finalTask: Task<Void, Never>?
    private var finalTaskID: UUID?
    private var finalTiming: PipelineTiming?
    private var recoveryTask: Task<Void, Never>?
    private var recovery = SpeechRecoveryState()
    // Every asynchronous callback belongs to one engine lifetime. Cancellation
    // alone is insufficient: Speech callbacks can arrive after a restart.
    private var lifecycle = UUID()
    private var isStarting = false
    private var executionInProgress = false
    private var presentedActive = false
    private var publishedPartial = ""
    private var lastLevel = 0.0
    private var lastLevelUpdateAt: TimeInterval = 0
    private var activityGate = SpeechActivityGate()

    init(purpose: Purpose = .commands) { self.purpose = purpose }

    func resetDictatedUtterance() {
        guard purpose == .menuDictation, isRunning else { return }
        resetUtterance()
    }

    /// A key or mode change expires pending audio, sessions and results. New
    /// settings take effect in local standby, and only a fresh wake can upload.
    func configureKrisp(enabled: Bool, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enabled != krispEnabled || key != krispKey else { return }
        let restart = krispEnabled || enabled
        krispEnabled = enabled
        krispKey = key
        if restart, isEnabled, tapInstalled { returnToStandby() }
    }

    func start() async throws {
        guard !isEnabled else { return }
        recovery.enable()
        let enableID = recovery.sessionID
        do { try await startEngine() } catch {
            if recovery.sessionID == enableID { stop() }
            throw error
        }
    }

    private func startEngine() async throws {
        guard recovery.isEnabled, !isRunning, !isStarting else { return }
        isStarting = true
        let startID = UUID()
        lifecycle = startID
        let task = Task<Void, Error> { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.prepare(startID: startID)
        }
        // Keep an owned task so Pause Microphone cancels an asset download too.
        startupTask = task
        defer {
            if lifecycle == startID { isStarting = false; startupTask = nil }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            if lifecycle == startID { shutDownEngine() }
            throw error
        }
    }

    private func prepare(startID: UUID) async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil else { throw InputError.missingUsageDescription }
        let needsPrompt = AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined
        if needsPrompt { onMicrophonePermissionPrompt?(true) }
        let authorized = await Self.microphoneAuthorization()
        if needsPrompt { onMicrophonePermissionPrompt?(false) }
        try ensureCurrent(startID)
        guard authorized else { throw InputError.microphoneDenied }
        onStatus?("Preparing Apple's speech transcriber…")
        let selectedLocale = try await SpeechRuntimeSetup.supportedEnglishLocale()
        let transcriber = SpeechTranscriber(locale: selectedLocale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
        try await SpeechRuntimeSetup.ensureAssets(for: [transcriber], locale: selectedLocale, allowsDownload: true) { [weak self] status in
            guard let self, self.lifecycle == startID else { return }
            self.onStatus?(status)
        }
        try ensureCurrent(startID)
        let engine = AVAudioEngine()
        // Use the microphone's normal input path. Enabling voice processing
        // replaces the audio unit and can change routing and captured levels.
        let naturalFormat = engine.inputNode.outputFormat(forBus: 0)
        guard naturalFormat.sampleRate > 0, naturalFormat.channelCount > 0 else { throw InputError.noMicrophone }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: naturalFormat) else { throw InputError.formatUnavailable }
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Hey Atmos", "Atmos"]
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        try ensureCurrent(startID)

        installPreparedRecognition(locale: selectedLocale, analyzer: analyzer, engine: engine)
        liveBoundary = makeLiveBoundary(analyzer: analyzer, format: format, lifecycle: startID)
        recognitionFormat = format
        captureFormat = naturalFormat
        let feed = try makeFeed(inputFormat: naturalFormat, targetFormat: format, lifecycle: startID)
        self.feed = feed
        feed.setSensitivity(audioSensitivity)
        activityGate = SpeechActivityGate(lastSpeechAt: feed.meter().lastSpeechAt)
        isRunning = true
        presentActivation(false)
        startReceivingResults(from: transcriber, lifecycle: startID)
        try await analyzer.start(inputSequence: feed.inputSequence)
        try ensureCurrent(startID)
        try startCapture(engine: engine, feed: feed, format: naturalFormat, lifecycle: startID)
    }

    private func installPreparedRecognition(locale: Locale, analyzer: SpeechAnalyzer, engine: AVAudioEngine) {
        session = WakeSession()
        session.setExecuting(executionInProgress, at: Self.now)
        transcript = SpeechTranscriptState()
        history = []
        snapshotFloor = 0
        resetCaptureFloor = 0
        self.locale = locale
        self.analyzer = analyzer
        self.engine = engine
    }

    private func makeLiveBoundary(analyzer: SpeechAnalyzer, format: AVAudioFormat, lifecycle startID: UUID) -> SpeechBoundarySynchronizer {
        let streamID = recognitionID
        let sampleTimescale = CMTimeScale(format.sampleRate.rounded())
        return SpeechBoundarySynchronizer(finalize: { [weak self] through in
            guard let self, self.isRunning, self.lifecycle == startID, self.recognitionID == streamID else { throw CancellationError() }
            try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: sampleTimescale))
        }, onFailure: { [weak self] error in
            guard let self, self.isRunning, self.lifecycle == startID, self.recognitionID == streamID else { return }
            self.fail("Apple's live speech stream could not advance to the next utterance: \(error.localizedDescription)", lifecycle: startID)
        })
    }

    private func startReceivingResults(from transcriber: SpeechTranscriber, lifecycle startID: UUID) {
        let streamID = recognitionID
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.isRunning, self.lifecycle == startID, self.recognitionID == streamID, !Task.isCancelled else { return }
                    self.receive(result)
                }
                if let self, self.isRunning, self.lifecycle == startID, self.recognitionID == streamID, !Task.isCancelled {
                    self.fail("Apple's live speech stream ended unexpectedly.", lifecycle: startID)
                }
            } catch is CancellationError {} catch {
                guard let self, self.recognitionID == streamID else { return }
                self.fail(error.localizedDescription, lifecycle: startID)
            }
        }
    }

    private func startCapture(engine: AVAudioEngine, feed: SpeechAudioFeed, format: AVAudioFormat, lifecycle startID: UUID) throws {
        if krispEnabled {
            let capture = KrispMicrophoneCapture(standby: feed) { [weak self] message in
                Task { @MainActor in self?.fail(message, lifecycle: startID) }
            }
            self.capture = capture
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, time in capture.append(buffer, at: time) }
        } else {
            engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fail(InputError.microphoneChanged.localizedDescription, lifecycle: startID) }
        }
        startTimer(lifecycle: startID)
        if purpose == .commands {
            onStatus?(executionInProgress ? "Working · say “stop” to sleep" : "Say “Hey Atmos”")
        }
    }

    func stop() {
        recovery.disable()
        recoveryTask?.cancel(); recoveryTask = nil
        shutDownEngine()
        onStatus?("Microphone off")
    }

    private func shutDownEngine() {
        lifecycle = UUID()
        recognitionID = UUID()
        isolationStartedAt = nil
        isolatedEndpoint = IsolatedSpeechEndpoint()
        wakeWindow = WakeAudioWindow()
        verifyingWake = false
        heardCleanWake = false
        isolationSetup?.cancel(); isolationSetup = nil
        capture?.stop(); capture = nil
        recognitionFormat = nil
        captureFormat = nil
        isRunning = false
        startupTask?.cancel()
        startupTask = nil
        isStarting = false
        timerTask?.cancel(); timerTask = nil
        resultsTask?.cancel(); resultsTask = nil
        cancelFinalPass()
        liveBoundary?.cancel(); liveBoundary = nil
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
        lastLevelUpdateAt = 0
        activityGate = SpeechActivityGate()
        onLevel?(0)
        publishPartial("")
    }

    func activate() {
        guard isRunning, !session.isExecuting else { return }
        resetUtterance()
        let events = session.activate(at: Self.now)
        if !startIsolation(on: events, manualStart: resetCaptureFloor) { handle(events) }
    }

    func deactivate() {
        resetUtterance()
        handle(session.deactivate())
    }

    func setExecuting(_ executing: Bool) {
        executionInProgress = executing
        // Keep the microphone's in-progress words/audio across model requests
        // and action completion so the user can continue or revise the task.
        session.setExecuting(executing, at: Self.now)
        guard isRunning else { return }
        onStatus?(executing ? "Working · say “stop” to sleep" : session.isActive ? "Listening…" : "Say “Hey Atmos”")
    }

    private func makeFeed(inputFormat: AVAudioFormat, targetFormat: AVAudioFormat, lifecycle id: UUID) throws -> SpeechAudioFeed {
        let streamID = recognitionID
        return try SpeechAudioFeed(inputFormat: inputFormat, targetFormat: targetFormat) { [weak self] packet in
            await self?.receiveAudio(packet, lifecycle: id, stream: streamID) ?? false
        } onFailure: { [weak self] message in
            await self?.feedFailed(message, lifecycle: id, stream: streamID)
        }
    }

    private func feedFailed(_ message: String, lifecycle id: UUID, stream streamID: UUID) {
        guard recognitionID == streamID else { return }
        fail(message, lifecycle: id)
    }

    /// Translate Apple's audio position to the physical microphone clock before
    /// retiring standby recognition. A single "wake + command" can span the switch.
    private var wakeCaptureStart: WakeAudioWindow.Selection? {
        guard krispEnabled, isolationStartedAt == nil, let earliest = history.first, let latest = history.last else { return nil }
        var attributed: TimeInterval?
        if let start = transcript.firstTextStart, let packet = history.first(where: { $0.endSeconds > start }),
           packet.startSeconds <= start + 0.001 {
            attributed = packet.capturedAt - (packet.endSeconds - start)
        }
        let evidence = wakeWindow.prefixTime ?? latest.capturedAt
        var onset: TimeInterval?
        var previous: TimeInterval?
        for packet in history.reversed() {
            if packet.capturedAt > evidence { continue }
            if packet.capturedAt < evidence - 2 { break }
            guard packet.containsSpeech else { continue }
            if let previous, previous - packet.capturedAt > 0.35 { break }
            onset = packet.capturedAt - (packet.endSeconds - packet.startSeconds)
            previous = packet.capturedAt
        }
        return wakeWindow.select(attributedStart: attributed,
            earliest: max(latest.capturedAt - 7.9, earliest.capturedAt - (earliest.endSeconds - earliest.startSeconds)),
            latest: latest.capturedAt, recentOnset: onset)
    }

    /// Manual activation has no historical audio. A spoken wake instead seeds a
    /// fresh analyzer with the isolated wake utterance, never its raw transcript.
    private func startIsolation(on events: [WakeSession.Event], from wakeStart: WakeAudioWindow.Selection? = nil,
                                manualStart: TimeInterval? = nil) -> Bool {
        guard krispEnabled, isolationStartedAt == nil, session.isActive, events.contains(.activated) else { return false }
        guard !krispKey.isEmpty else {
            returnToStandby(reason: KrispMicrophoneCapture.Failure.missingKey.localizedDescription)
            return true
        }
        let id = lifecycle
        do {
            guard let capture, let captureFormat, let locale, let format = recognitionFormat else { throw InputError.unavailableAudio }
            if manualStart == nil, wakeStart == nil { throw KrispMicrophoneCapture.Failure.missingWakeAudio }
            recognitionID = UUID()
            let streamID = recognitionID
            isolationStartedAt = Self.now
            cancelFinalPass()
            resultsTask?.cancel()
            liveBoundary?.cancel()
            if let analyzer { Task { await analyzer.cancelAndFinishNow() } }
            let clean = try makeFeed(inputFormat: KrispMicrophoneStream.wireFormat, targetFormat: format, lifecycle: id)
            clean.setSensitivity(sensitivity)
            let stream = try KrispMicrophoneStream(apiKey: krispKey, inputFormat: captureFormat,
                                                    output: clean) { [weak self] message in
                await self?.isolationFailed(message, lifecycle: id, stream: streamID)
            }
            do { try capture.begin(stream, from: wakeStart?.start ?? manualStart ?? Self.now, requireWake: manualStart == nil) }
            catch { stream.stop(); clean.stop(); throw error }
            feed?.stop()
            feed = clean
            history.removeAll()
            snapshotFloor = 0
            resetCaptureFloor = 0
            transcript = SpeechTranscriptState()
            verifyingWake = wakeStart?.verifyWake ?? false
            heardCleanWake = false
            activityGate = SpeechActivityGate()
            session.beginRecognition()
            publishPartial("")
            presentActivation(true)
            onStatus?("Connecting Krisp VIVA Pro…")

            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
            let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
            self.analyzer = analyzer
            liveBoundary = makeLiveBoundary(analyzer: analyzer, format: format, lifecycle: id)
            isolationSetup = Task { @MainActor [weak self] in
                do {
                    let context = AnalysisContext()
                    context.contextualStrings[.general] = ["Hey Atmos", "Atmos"]
                    try await analyzer.setContext(context)
                    try await analyzer.prepareToAnalyze(in: format)
                    try Task.checkCancellation()
                    guard let self, self.recognitionID == streamID, self.lifecycle == id else { return }
                    self.startReceivingResults(from: transcriber, lifecycle: id)
                    try await analyzer.start(inputSequence: clean.inputSequence)
                } catch is CancellationError {} catch {
                    self?.isolationFailed(error.localizedDescription, lifecycle: id, stream: streamID)
                }
            }
        } catch { returnToStandby(reason: error.localizedDescription) }
        return true
    }

    private func isolationFailed(_ message: String, lifecycle id: UUID, stream streamID: UUID) {
        guard isRunning, lifecycle == id, recognitionID == streamID else { return }
        returnToStandby(reason: "Krisp VIVA Pro: \(message)")
    }

    private func returnToStandby(reason: String? = nil) {
        if purpose == .menuDictation {
            failDictation(reason ?? "Voice isolation settings changed. Start dictation again.")
            return
        }
        let enabledID = recovery.sessionID
        let wasActive = session.isActive || presentedActive
        recoveryTask?.cancel()
        shutDownEngine()
        if wasActive { executionInProgress = false; onDeactivation?() }
        guard isEnabled else { return }
        onStatus?(reason ?? "Returning to standby…")
        recoveryTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, self.recovery.sessionID == enabledID else { return }
            do {
                try await self.startEngine()
                try Task.checkCancellation()
                if let reason { self.onStatus?("\(reason) · Say “Hey Atmos” to retry") }
            } catch is CancellationError {} catch {
                guard self.recovery.sessionID == enabledID, !Task.isCancelled else { return }
                self.scheduleRecovery(after: error.localizedDescription)
            }
        }
    }

    private func receiveAudio(_ packet: SpeechAudioPacket, lifecycle id: UUID, stream streamID: UUID) -> Bool {
        guard isRunning, lifecycle == id, recognitionID == streamID else { return false }
        if isolationStartedAt != nil, history.isEmpty, transcript.audioEnd == 0 { onStatus?("Listening · Krisp VIVA Pro") }
        let meter = feed?.meter()
        if transcript.observeAudio(end: packet.endSeconds, lastSpeechAt: meter?.lastSpeechAt ?? Self.now, convertedCaptureAt: packet.capturedAt) { cancelFinalPass() }
        // A reset also excludes audio captured earlier but still awaiting conversion,
        // and drops a single packet straddling the boundary rather than replaying it.
        if packet.capturedAt - (packet.endSeconds - packet.startSeconds) < resetCaptureFloor {
            snapshotFloor = packet.endSeconds
            transcript.discard(through: packet.endSeconds)
            synchronizeLiveBoundary()
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
        if transcript.replace(start: start, end: end, with: pieces, at: endpointClock) { cancelFinalPass() }
        publishPreview()
    }

    private func publishPreview() {
        if purpose == .menuDictation {
            // The pre-activation raw stream cannot populate the editor when
            // isolation is requested. Only results from the clean feed qualify.
            if canDictate { publishPartial(transcript.text) }
            return
        }
        // Wake and first-word Stop are deliberately immediate. Ordinary words
        // wait for a stable endpoint and, when enabled, the accurate replay.
        if krispEnabled, isolationStartedAt == nil, !session.isActive, let capturedAt = transcript.convertedCaptureAt {
            wakeWindow.observe(transcript.text, at: capturedAt)
        }
        if verifyingWake, WakeAudioWindow.containsWake(transcript.text) { heardCleanWake = true }
        let events = session.receive(transcript.text, at: Self.now)
        if events.contains(.activated), startIsolation(on: events, from: wakeCaptureStart) { return }
        if events.contains(.deactivated) { resetUtterance() }
        handle(events)
        presentActivation(session.isActive)
    }

    private func startTimer(lifecycle id: UUID) {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(10)) } catch { return }
                guard let self, self.isRunning, self.lifecycle == id else { return }
                self.tick(lifecycle: id)
            }
        }
    }

    private func tick(lifecycle id: UUID) {
        guard let feed else { return }
        let now = Self.now
        let meter = feed.meter()
        // Track unconsumed audio for transcript/idle UI state. Raw sound no
        // longer interrupts computer actions; only accepted speech can do that.
        _ = activityGate.observe(lastSpeechAt: meter.lastSpeechAt)
        guard isRunning, lifecycle == id else { return }
        // Check the short endpoint frequently without increasing UI meter updates.
        if now - lastLevelUpdateAt >= 0.1 {
            lastLevelUpdateAt = now
            lastLevel = lastLevel * 0.65 + min(1, meter.rms * 14) * 0.35
            onLevel?(lastLevel)
        }
        let capturedThrough = capture?.lastCaptureTime() ?? meter.lastBufferAt
        if verifyingWake, WakeAudioWindow.emptyConfirmationExpired(audioDuration: transcript.audioEnd,
            hasWords: !transcript.text.isEmpty, heardWake: heardCleanWake, silence: endpointClock - meter.lastSpeechAt) {
            returnToStandby(reason: KrispMicrophoneCapture.Failure.unverifiedWake.localizedDescription)
            return
        }
        if now - capturedThrough > 3 { fail(InputError.audioStalled.localizedDescription, lifecycle: id); return }
        if let isolationStartedAt, now - max(isolationStartedAt, meter.lastBufferAt) > 8 {
            returnToStandby(reason: KrispMicrophoneCapture.Failure.stalled.localizedDescription)
            return
        }
        if transcript.observeAudio(end: transcript.audioEnd, lastSpeechAt: meter.lastSpeechAt) { cancelFinalPass() }
        let progress = endpointClock
        _ = activityGate.finishIdle(at: progress, lastSpeechAt: meter.lastSpeechAt,
            lastResultAt: transcript.lastResultAt, hasUnfinishedText: !transcript.text.isEmpty,
            isFinalizing: finalTask != nil)
        guard isRunning, lifecycle == id else { return }
        // Without replay, Apple can revise the last words after a short pause.
        // Leave the editor's live span revisable; the user may still send it now.
        let endpointSilence = purpose == .menuDictation && !secondPassEnabled
            ? 1.15 : SpeechAudioHistoryPolicy.endpointSilence
        if isolationStartedAt != nil {
            guard !transcript.text.isEmpty, let cleaned = transcript.convertedCaptureAt,
                  isolatedEndpoint.ready(cleanThrough: cleaned, capturedThrough: capturedThrough,
                    lastActivity: max(meter.lastSpeechAt, transcript.lastResultAt),
                    silence: endpointSilence) else { return }
        }
        guard finalTask == nil, let candidate = transcript.beginFinalization(at: progress,
            silenceDuration: endpointSilence, latestCaptureAt: meter.lastBufferAt) else { return }
        beginFinalPass(candidate, at: now, lifecycle: id)
    }

    private var endpointClock: TimeInterval {
        if isolationStartedAt != nil, let through = transcript.convertedCaptureAt { return through }
        return Self.now
    }

    /// Freeze both text and audio from the same endpoint. Coverage checks must
    /// compare the replay with this snapshot, not with later volatile results.
    private struct UtteranceReplay: Sendable {
        let candidate: SpeechTranscriptState.Candidate
        let packets: [SpeechAudioPacket]
        let locale: Locale
        let firstTextStart: TimeInterval?
        let provisionalText: String
    }

    private func beginFinalPass(_ candidate: SpeechTranscriptState.Candidate, at now: TimeInterval, lifecycle id: UUID) {
        if purpose == .menuDictation, !canDictate {
            _ = transcript.commit(candidate)
            synchronizeLiveBoundary()
            trimHistory()
            return
        }
        var preview = session
        preview.beginRecognition(preservingPending: false)
        _ = preview.receive(transcript.text, at: now)
        if !session.isActive && !session.isExecuting && !preview.isActive && !WakeSession.isPossibleWakePrefix(transcript.text) {
            _ = transcript.commit(candidate)
            wakeWindow = WakeAudioWindow()
            session.beginRecognition(preservingPending: false)
            synchronizeLiveBoundary()
            trimHistory()
            return
        }
        if !secondPassEnabled {
            commitLivePass(candidate, lifecycle: id)
            return
        }
        guard let locale, !history.isEmpty else {
            fail(InputError.unavailableAudio.localizedDescription, lifecycle: id)
            return
        }
        // A coarse ASR range may start in old silence that was trimmed. Actual
        // detected speech is retained independently of result timestamps, so an
        // old range start alone is not evidence of missing command audio.
        // Keep real leading context and the full observed trailing silence.
        let from = max(snapshotFloor, transcript.consumedThrough - SpeechAudioHistoryPolicy.leadingContext)
        let packets = history.filter {
            $0.startSeconds >= snapshotFloor && $0.endSeconds > from && $0.startSeconds < candidate.through
        }
        guard !packets.isEmpty else {
            fail(InputError.unavailableAudio.localizedDescription, lifecycle: id)
            return
        }
        let replay = UtteranceReplay(
            candidate: candidate, packets: packets, locale: locale,
            firstTextStart: transcript.firstTextStart, provisionalText: transcript.text
        )
        startFinalPass(replay, lifecycle: id)
    }

    private func startFinalPass(_ replay: UtteranceReplay, lifecycle id: UUID) {
        let candidate = replay.candidate
        let timing = startSpeechTiming(candidate, usesReplay: true)
        guard isRunning, lifecycle == id, finalTaskID == candidate.id,
              transcript.isCurrent(candidate) else {
            timing.finish(.cancelled)
            return
        }
        let replaySpan = timing.begin("Local speech replay")
        finalTask = Task { @MainActor [weak self] in
            do {
                let finalText = try await Self.finalizeWithTimeout(replay, timing: timing)
                timing.end(replaySpan, outcome: .succeeded)
                guard let self, self.isRunning, self.lifecycle == id, !Task.isCancelled else {
                    timing.finish(.cancelled)
                    return
                }
                // New microphone audio can arrive while Apple is replaying. Let
                // the isolated feed classify that interval before accepting text.
                if self.isolationStartedAt != nil, let capturedThrough = self.capture?.lastCaptureTime() {
                    while (self.transcript.convertedCaptureAt ?? 0) < capturedThrough {
                        try Task.checkCancellation()
                        guard self.isRunning, self.lifecycle == id, self.transcript.isCurrent(candidate) else {
                            timing.finish(.cancelled)
                            return
                        }
                        try await Task.sleep(for: .milliseconds(10))
                    }
                }
                guard self.commitFinalPass(replay, text: finalText, lifecycle: id, timing: timing) else { return }
            } catch is CancellationError {
                timing.end(replaySpan, outcome: .cancelled)
                timing.finish(.cancelled)
            } catch {
                timing.end(replaySpan, outcome: .failed)
                timing.finish(.failed)
                guard let self, self.lifecycle == id, self.transcript.isCurrent(candidate) else { return }
                self.fail(error.localizedDescription, lifecycle: id)
            }
            // A callback may have started another utterance while delivering this
            // result. Only the task that still owns this ID may clear its handle.
            if let self, self.finalTaskID == candidate.id {
                self.finalTask = nil
                self.finalTaskID = nil
                self.finalTiming = nil
            }
        }
    }

    private func startSpeechTiming(_ candidate: SpeechTranscriptState.Candidate, usesReplay: Bool) -> PipelineTiming {
        let endpointReachedAt = Self.now
        let lastSpeechAt = feed?.meter().lastSpeechAt ?? endpointReachedAt
        // Start at the last detected speech, so the silence endpoint and any
        // delayed recognition/conversion are included in time until the click.
        let endpointStartedAt = lastSpeechAt.isFinite && lastSpeechAt > 0 && lastSpeechAt <= endpointReachedAt
            ? lastSpeechAt : endpointReachedAt
        let timing = PipelineTiming(origin: .speech, startedAt: endpointStartedAt)
        timing.record("Speech endpoint wait", from: endpointStartedAt, to: endpointReachedAt)
        timing.annotate(usesReplay ? "Speech transcription: live + second pass" : "Speech transcription: fast live only; second pass skipped")
        finalTaskID = candidate.id
        finalTiming = timing
        // The app must associate the trace before speculative capture starts.
        // Even a wake-only utterance is visible and will finish as ignored.
        onTimingStarted?(candidate.id, timing)
        if session.isActive { onFinalizationStarted?(candidate.id) }
        return timing
    }

    private func commitLivePass(_ candidate: SpeechTranscriptState.Candidate, lifecycle id: UUID) {
        let wakeStart = wakeCaptureStart
        let timing = startSpeechTiming(candidate, usesReplay: false)
        let validationSpan = timing.begin("Fast speech commit validation")
        // Timing/capture callbacks can synchronously stop or reset the session.
        // Check ownership again before accepting text or clearing another trace.
        guard isRunning, lifecycle == id, finalTaskID == candidate.id else {
            timing.end(validationSpan, outcome: .cancelled)
            timing.finish(.cancelled)
            return
        }
        guard let meter = feed?.meter(), let text = transcript.commitLiveTranscript(
            candidate, at: endpointClock, lastSpeechAt: meter.lastSpeechAt, latestCaptureAt: meter.lastBufferAt
        ) else {
            timing.end(validationSpan, outcome: .cancelled)
            cancelFinalPass()
            return
        }
        finishCommittedSpeech(lastSpeechAt: meter.lastSpeechAt)
        timing.end(validationSpan, outcome: .succeeded)
        publishFinalizedText(text, candidateID: candidate.id, timing: timing, wakeStart: wakeStart)
    }

    private static func finalizeWithTimeout(_ replay: UtteranceReplay, timing: PipelineTiming) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await SpeechUtteranceFinalizer.transcribe(replay.packets, locale: replay.locale, timing: timing)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(12))
                throw InputError.finalizationTimedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? ""
        }
    }

    private func commitFinalPass(_ replay: UtteranceReplay, text: String, lifecycle id: UUID, timing: PipelineTiming) -> Bool {
        let validationSpan = timing.begin("Speech commit validation")
        guard let meter = feed?.meter() else {
            timing.end(validationSpan, outcome: .cancelled)
            cancelFinalPass()
            return false
        }
        if transcript.observeAudio(end: transcript.audioEnd, lastSpeechAt: meter.lastSpeechAt)
            || !transcript.audioIsCaughtUp(at: endpointClock, latestCaptureAt: meter.lastBufferAt) {
            timing.end(validationSpan, outcome: .cancelled)
            cancelFinalPass()
            return false
        }
        guard SpeechAudioHistoryPolicy.replayHasCompleteCoverage(
            firstTextStart: replay.firstTextStart, retainedAudioStart: replay.packets[0].startSeconds,
            provisionalText: replay.provisionalText, finalText: text
        ) else {
            timing.end(validationSpan, outcome: .failed)
            timing.finish(.failed)
            fail(InputError.incompleteReplay.localizedDescription, lifecycle: id)
            return false
        }
        let wakeStart = wakeCaptureStart
        guard transcript.commit(replay.candidate) else {
            timing.end(validationSpan, outcome: .cancelled)
            cancelFinalPass()
            return false
        }
        finishCommittedSpeech(lastSpeechAt: meter.lastSpeechAt)
        timing.end(validationSpan, outcome: .succeeded)
        publishFinalizedText(text, candidateID: replay.candidate.id, timing: timing, wakeStart: wakeStart)
        return true
    }

    private func finishCommittedSpeech(lastSpeechAt: TimeInterval) {
        wakeWindow = WakeAudioWindow()
        activityGate.consume(lastSpeechAt: lastSpeechAt)
        synchronizeLiveBoundary()
        finalTask = nil
        finalTaskID = nil
        finalTiming = nil
        trimHistory()
    }

    private func publishFinalizedText(_ text: String, candidateID: UUID, timing: PipelineTiming, wakeStart: WakeAudioWindow.Selection?) {
        if purpose == .menuDictation {
            if canDictate { onDictatedUtterance?(text) }
            timing.finish(.succeeded)
            publishPartial("")
            return
        }
        if verifyingWake {
            guard WakeAudioWindow.containsWake(text) else {
                timing.finish(.ignored)
                onFinalizationInvalidated?(candidateID)
                returnToStandby(reason: KrispMicrophoneCapture.Failure.unverifiedWake.localizedDescription)
                return
            }
            verifyingWake = false
        }
        // Fast wake has already activated the session. Both recognition paths
        // strip a repeated wake before delivering the selected transcript.
        session.beginRecognition(preservingPending: false)
        let previewEvents = session.receive(text, at: Self.now)
        if startIsolation(on: previewEvents, from: wakeStart) {
            timing.finish(.ignored)
            onFinalizationInvalidated?(candidateID)
            return
        }
        handle(previewEvents, candidateID: candidateID)
        presentActivation(session.isActive)
        let events = session.finishUtterance(at: Self.now)
        // The transcript now excludes committed audio. Its next live result is
        // a new utterance. Reset this word boundary before reentrant app callbacks.
        session.beginRecognition(preservingPending: false)
        handle(events, candidateID: candidateID)
        if !events.contains(where: { if case .command = $0 { return true }; return false }) {
            timing.finish(.ignored)
            onFinalizationInvalidated?(candidateID)
        }
        if !session.isExecuting { publishPartial("") }
    }

    private func handle(_ events: [WakeSession.Event], candidateID: UUID? = nil) {
        for event in events {
            switch event {
            case .activated:
                presentActivation(true)
                onStatus?("Listening…")
            case .partial(let text): publishPartial(text)
            case .command(let text):
                publishedPartial = ""
                if let candidateID, let onFinalizedCommand { onFinalizedCommand(text, candidateID) }
                else { onCommand?(text) }
            case .ignored: publishPartial("")
            case .deactivated:
                if isolationStartedAt != nil {
                    returnToStandby()
                    return
                }
                executionInProgress = false
                presentActivation(false)
                publishPartial("")
                onDeactivation?()
                onStatus?(isRunning ? "Say “Hey Atmos”" : "Microphone off")
            }
        }
    }

    private func resetUtterance() {
        wakeWindow = WakeAudioWindow()
        cancelFinalPass()
        snapshotFloor = transcript.audioEnd
        resetCaptureFloor = Self.now
        transcript.discard(through: transcript.audioEnd)
        activityGate.consume(lastSpeechAt: feed?.meter().lastSpeechAt ?? Self.now)
        synchronizeLiveBoundary()
        session.beginRecognition(preservingPending: false)
        trimHistory()
        publishPartial("")
    }

    private func synchronizeLiveBoundary() {
        // The accurate replay and live recognizer have independent boundaries.
        // Once Atmos consumes audio, close that part of the live stream too;
        // otherwise Apple's next coarse partial can start before consumedThrough
        // and hide all its new words. This neither submits text nor clears it.
        liveBoundary?.request(through: transcript.consumedThrough)
    }

    private func trimHistory() {
        let firstSpeech = history.first { $0.containsSpeech && $0.endSeconds > transcript.consumedThrough }?.startSeconds
        let keepFrom = SpeechAudioHistoryPolicy.keepFrom(consumedThrough: transcript.consumedThrough, audioEnd: transcript.audioEnd,
            firstUnconsumedSpeechStart: firstSpeech, hasUnfinishedText: !transcript.text.isEmpty || transcript.candidate != nil)
        history.removeAll { $0.startSeconds < snapshotFloor || $0.endSeconds <= keepFrom }
    }

    private func cancelFinalPass() {
        finalTiming?.finish(.cancelled)
        finalTiming = nil
        if let finalTaskID { onFinalizationInvalidated?(finalTaskID) }
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

    private var canDictate: Bool {
        session.isActive && (!krispEnabled || isolationStartedAt != nil)
    }

    private func failDictation(_ message: String) {
        // Give the editor its last visible words before stop clears the partial.
        onFailure?(message)
        if isEnabled { stop() }
    }

    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle == id else { throw CancellationError() }
    }

    private func fail(_ message: String, lifecycle id: UUID) {
        guard lifecycle == id else { return }
        if purpose == .menuDictation {
            failDictation(message)
            return
        }
        // Drop incomplete text/audio, cancel actions, and recover in standby.
        // Explicit microphone pause invalidates this entire retry generation.
        shutDownEngine()
        executionInProgress = false
        onDeactivation?()
        scheduleRecovery(after: message)
    }

    private func scheduleRecovery(after message: String) {
        guard let attempt = recovery.nextAttempt(at: Self.now) else {
            stop()
            let detail = "Voice could not recover after repeated interruptions. Enable the microphone to retry. \(message)"
            onFailure?(detail)
            onStatus?(detail)
            return
        }
        onStatus?("Reconnecting microphone… Unfinished command discarded.")
        recoveryTask?.cancel()
        recoveryTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(attempt.delay))
                guard let self, self.recovery.isCurrent(attempt), !Task.isCancelled else { return }
                try await self.startEngine()
                guard self.recovery.isCurrent(attempt), !Task.isCancelled else { return }
                self.recoveryTask = nil
                self.onStatus?("Voice restored · say “Hey Atmos” and repeat your command")
            } catch is CancellationError {
            } catch {
                guard let self, self.recovery.isCurrent(attempt), !Task.isCancelled else { return }
                self.scheduleRecovery(after: error.localizedDescription)
            }
        }
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
