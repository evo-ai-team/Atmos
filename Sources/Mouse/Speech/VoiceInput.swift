import AVFoundation
import CoreMedia
import Foundation
import Speech
#if SWIFT_PACKAGE
import MouseCore
#endif

@MainActor
final class VoiceInput {
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
            case .microphoneDenied: return "Allow Mouse microphone access in System Settings → Privacy & Security."
            case .noMicrophone: return "No microphone is available. Connect one, then enable the microphone again."
            case .missingUsageDescription: return "Launch the packaged Mouse app to enable microphone permissions."
            case .formatUnavailable: return "Apple's speech model has no compatible audio format on this Mac."
            case .microphoneChanged: return "The microphone changed. The unfinished command was discarded."
            case .audioStalled: return "The microphone stopped providing audio."
            case .utteranceTooLong: return "The unfinished utterance exceeded one minute and was discarded."
            case .unavailableAudio: return "Audio for the unfinished command is unavailable."
            case .incompleteReplay: return "Mouse could not verify the beginning of that command. Please repeat the full command."
            case .finalizationTimedOut: return "The speech model could not finalize this utterance. The unfinished text was discarded."
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
        guard await Self.microphoneAuthorization() else { throw InputError.microphoneDenied }
        try ensureCurrent(startID)
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
        context.contextualStrings[.general] = ["Hey Mouse", "Mouse"]
        try await analyzer.setContext(context)
        try await analyzer.prepareToAnalyze(in: format)
        try ensureCurrent(startID)

        installPreparedRecognition(locale: selectedLocale, analyzer: analyzer, engine: engine)
        liveBoundary = makeLiveBoundary(analyzer: analyzer, format: format, lifecycle: startID)
        let feed = try SpeechAudioFeed(inputFormat: naturalFormat, targetFormat: format) { [weak self] packet in
            await self?.receiveAudio(packet, lifecycle: startID) ?? false
        } onFailure: { [weak self] message in
            await self?.fail(message, lifecycle: startID)
        }
        self.feed = feed
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
        let sampleTimescale = CMTimeScale(format.sampleRate.rounded())
        return SpeechBoundarySynchronizer(finalize: { [weak self] through in
            guard let self, self.isRunning, self.lifecycle == startID else { throw CancellationError() }
            try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: sampleTimescale))
        }, onFailure: { [weak self] error in
            guard let self, self.isRunning, self.lifecycle == startID else { return }
            self.fail("Apple's live speech stream could not advance to the next utterance: \(error.localizedDescription)", lifecycle: startID)
        })
    }

    private func startReceivingResults(from transcriber: SpeechTranscriber, lifecycle startID: UUID) {
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self, self.isRunning, self.lifecycle == startID, !Task.isCancelled else { return }
                    self.receive(result)
                }
                if let self, self.isRunning, self.lifecycle == startID, !Task.isCancelled {
                    self.fail("Apple's live speech stream ended unexpectedly.", lifecycle: startID)
                }
            } catch is CancellationError {} catch {
                self?.fail(error.localizedDescription, lifecycle: startID)
            }
        }
    }

    private func startCapture(engine: AVAudioEngine, feed: SpeechAudioFeed, format: AVAudioFormat, lifecycle startID: UUID) throws {
        engine.inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in feed.append(buffer) }
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
        recovery.disable()
        recoveryTask?.cancel(); recoveryTask = nil
        shutDownEngine()
        onStatus?("Microphone off")
    }

    private func shutDownEngine() {
        lifecycle = UUID()
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
        handle(session.activate(at: Self.now))
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
        if transcript.replace(start: start, end: end, with: pieces, at: Self.now) { cancelFinalPass() }
        publishPreview()
    }

    private func publishPreview() {
        // Wake and first-word Stop are deliberately immediate. Ordinary live
        // words remain preview-only until the accurate replay completes.
        let events = session.receive(transcript.text, at: Self.now)
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
        if now - meter.lastBufferAt > 3 { fail(InputError.audioStalled.localizedDescription, lifecycle: id); return }
        if transcript.observeAudio(end: transcript.audioEnd, lastSpeechAt: meter.lastSpeechAt) { cancelFinalPass() }
        _ = activityGate.finishIdle(at: now, lastSpeechAt: meter.lastSpeechAt,
            lastResultAt: transcript.lastResultAt, hasUnfinishedText: !transcript.text.isEmpty,
            isFinalizing: finalTask != nil)
        guard isRunning, lifecycle == id else { return }
        guard finalTask == nil, let candidate = transcript.beginFinalization(at: now, silenceDuration: SpeechAudioHistoryPolicy.endpointSilence, latestCaptureAt: meter.lastBufferAt) else { return }
        beginFinalPass(candidate, at: now, lifecycle: id)
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
        var preview = session
        preview.beginRecognition(preservingPending: false)
        _ = preview.receive(transcript.text, at: now)
        if !session.isActive && !session.isExecuting && !preview.isActive && !WakeSession.isPossibleWakePrefix(transcript.text) {
            _ = transcript.commit(candidate)
            session.beginRecognition(preservingPending: false)
            synchronizeLiveBoundary()
            trimHistory()
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
        let replayStartedAt = Self.now
        let lastSpeechAt = feed?.meter().lastSpeechAt ?? replayStartedAt
        // Start at the last detected speech, so the silence endpoint and any
        // delayed recognition/conversion are included in time until the click.
        let endpointStartedAt = lastSpeechAt.isFinite && lastSpeechAt > 0 && lastSpeechAt <= replayStartedAt
            ? lastSpeechAt : replayStartedAt
        let timing = PipelineTiming(origin: .speech, startedAt: endpointStartedAt)
        timing.record("Speech endpoint wait", from: endpointStartedAt, to: replayStartedAt)
        finalTaskID = candidate.id
        finalTiming = timing
        // The app must associate the trace before speculative capture starts.
        // Even a wake-only replay is visible and will finish as ignored.
        onTimingStarted?(candidate.id, timing)
        if session.isActive { onFinalizationStarted?(candidate.id) }
        let replaySpan = timing.begin("Local speech replay")
        finalTask = Task { @MainActor [weak self] in
            do {
                let finalText = try await Self.finalizeWithTimeout(replay, timing: timing)
                timing.end(replaySpan, outcome: .succeeded)
                guard let self, self.isRunning, self.lifecycle == id, !Task.isCancelled else {
                    timing.finish(.cancelled)
                    return
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
            || !transcript.audioIsCaughtUp(at: Self.now, latestCaptureAt: meter.lastBufferAt) {
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
        guard transcript.commit(replay.candidate) else {
            timing.end(validationSpan, outcome: .cancelled)
            cancelFinalPass()
            return false
        }
        activityGate.consume(lastSpeechAt: meter.lastSpeechAt)
        synchronizeLiveBoundary()
        finalTask = nil
        finalTaskID = nil
        finalTiming = nil
        trimHistory()
        timing.end(validationSpan, outcome: .succeeded)
        publishFinalizedText(text, candidateID: replay.candidate.id, timing: timing)
        return true
    }

    private func publishFinalizedText(_ text: String, candidateID: UUID, timing: PipelineTiming) {
        // Fast wake has already activated the session. Replay still supplies
        // corrected command text and strips a repeated wake.
        session.beginRecognition(preservingPending: false)
        handle(session.receive(text, at: Self.now), candidateID: candidateID)
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
        activityGate.consume(lastSpeechAt: feed?.meter().lastSpeechAt ?? Self.now)
        synchronizeLiveBoundary()
        session.beginRecognition(preservingPending: false)
        trimHistory()
        publishPartial("")
    }

    private func synchronizeLiveBoundary() {
        // The accurate replay and live recognizer have independent boundaries.
        // Once Mouse consumes audio, close that part of the live stream too;
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

    private func ensureCurrent(_ id: UUID) throws {
        try Task.checkCancellation()
        guard lifecycle == id else { throw CancellationError() }
    }

    private func fail(_ message: String, lifecycle id: UUID) {
        guard lifecycle == id else { return }
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
                self.onStatus?("Voice restored · say “Hey Mouse” and repeat your command")
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
