import AVFoundation
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
    var onStop: (() -> Void)?
    private(set) var isRunning = false

    enum InputError: LocalizedError {
        case microphoneDenied, speechDenied, unavailable, noMicrophone, missingUsageDescriptions

        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Allow Chosen microphone access in System Settings → Privacy & Security."
            case .speechDenied: return "Allow Chosen speech recognition in System Settings → Privacy & Security."
            case .unavailable: return "On-device English speech recognition is unavailable. Enable English dictation in System Settings, then try again."
            case .noMicrophone: return "No microphone is available. Connect one, then try again."
            case .missingUsageDescriptions: return "Launch the packaged Chosen app to enable microphone permissions."
            }
        }
    }

    private var session = WakeSession()
    private var engine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audio = VoiceAudioRelay()
    private var configurationObserver: NSObjectProtocol?
    private var timerTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var generation = UUID()
    private var lifecycle = UUID()
    private var isStarting = false
    private var executionInProgress = false
    private var recognitionStartedAt: TimeInterval = 0
    private var recoveryAttempts = 0
    private var lastLevel = 0.0
    private let silenceDuration: TimeInterval = 0.7

    /// Call only from the user's explicit Enable Voice action. No permissions are
    /// requested by init(), activate(), background timers, or application launch.
    func start() async throws {
        guard !isRunning, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        let startID = UUID()
        lifecycle = startID
        guard Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil,
              Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
            throw InputError.missingUsageDescriptions
        }
        guard await Self.microphoneAuthorization() else { throw InputError.microphoneDenied }
        guard startID == lifecycle, !Task.isCancelled else { throw CancellationError() }
        guard await Self.speechAuthorization() else { throw InputError.speechDenied }
        guard startID == lifecycle, !Task.isCancelled else { throw CancellationError() }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition else { throw InputError.unavailable }

        self.recognizer = recognizer
        // Typed commands can already be running when voice is enabled. Preserve
        // their interruption state while resetting the newly opened wake stream.
        let alreadyExecuting = executionInProgress
        session = WakeSession()
        session.setExecuting(alreadyExecuting, at: Self.now)
        recoveryAttempts = 0
        do {
            try startAudioEngine()
            isRunning = true
            try beginRecognition(preservingPending: false)
            startTimer()
            onStatus?(alreadyExecuting ? "Working · say “stop” to interrupt" : "Say “Hey Chosen”")
        } catch {
            stop()
            throw error
        }
    }

    func stop() {
        lifecycle = UUID()
        isRunning = false
        timerTask?.cancel()
        timerTask = nil
        recoveryTask?.cancel()
        recoveryTask = nil
        endRecognition()
        endAudioEngine()
        recognizer = nil
        session = WakeSession()
        lastLevel = 0
        onLevel?(0)
        onPartial?("")
        onStatus?("Voice off")
    }

    /// Begins a command window without a wake phrase. Enabling the microphone is
    /// deliberately a separate, explicit user action through start().
    func activate() {
        guard isRunning else { return }
        if session.isExecuting {
            onStatus?("Working · say “stop” to interrupt")
            return
        }
        handle(session.activate(at: Self.now))
    }

    func setExecuting(_ executing: Bool) {
        executionInProgress = executing
        session.setExecuting(executing, at: Self.now)
        guard isRunning else { return }
        onStatus?(executing ? "Working · say “stop” to interrupt" : session.isActive ? "Listening for a follow-up" : "Say “Hey Chosen”")
    }

    private func startAudioEngine() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw InputError.noMicrophone }
        audio.resetMeter()
        let relay = audio
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            relay.append(buffer)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw InputError.noMicrophone
        }
        self.engine = engine
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recover(rebuildAudio: true) }
        }
    }

    private func endAudioEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
    }

    private func beginRecognition(preservingPending: Bool) throws {
        guard let recognizer, recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw InputError.unavailable
        }
        endRecognition()
        session.beginRecognition(preservingPending: preservingPending)
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = false
        request.taskHint = .dictation
        request.contextualStrings = ["Hey Chosen", "Chosen"]
        let token = UUID()
        generation = token
        recognitionStartedAt = Self.now
        audio.setRequest(request)
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            // Copy the values before crossing onto the actor; no audio or transcript
            // leaves this process except commands explicitly emitted by WakeSession.
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let hadError = error != nil
            Task { @MainActor [weak self] in
                guard let self, self.isRunning, self.generation == token else { return }
                if let transcript, !transcript.isEmpty {
                    self.recoveryAttempts = 0
                    self.handle(self.session.receive(transcript, at: Self.now))
                }
                // handle() may replace the recognition task after a command or stop.
                guard self.generation == token else { return }
                if hadError && !isFinal {
                    self.recoveryAttempts += 1
                    if self.recoveryAttempts >= 6 {
                        self.stop()
                        self.onStatus?(InputError.unavailable.localizedDescription)
                        return
                    }
                }
                if isFinal || hadError {
                    self.recover(rebuildAudio: false, quiet: isFinal)
                }
            }
        }
    }

    private func endRecognition() {
        generation = UUID()
        audio.setRequest(nil)
        recognitionTask?.cancel()
        recognitionTask = nil
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, self.isRunning else { return }
                self.tick()
            }
        }
    }

    private func tick() {
        let now = Self.now
        let meter = audio.meter()
        lastLevel = lastLevel * 0.65 + min(1, meter.rms * 14) * 0.35
        onLevel?(lastLevel)
        handle(session.expire(at: now))
        guard recoveryTask == nil else { return }
        guard engine?.isRunning == true else {
            recover(rebuildAudio: true)
            return
        }
        if !session.pendingCommand.isEmpty, let changed = session.lastChangeAt,
           now - max(changed, meter.lastSpeechAt) >= silenceDuration {
            handle(session.finishUtterance(at: now))
        }
        if now - recognitionStartedAt >= 50,
           now - meter.lastSpeechAt >= silenceDuration {
            // Renew before Speech's task-duration limit, at an acoustic boundary.
            // Any unfinished words survive a stream replacement.
            rotateRecognition()
        }
    }

    private func handle(_ events: [WakeSession.Event]) {
        for event in events {
            switch event {
            case .activated:
                onPartial?("")
                onStatus?("Listening…")
            case .partial(let text):
                onPartial?(text)
            case .command(let text):
                // Discard late callbacks from the committed stream before invoking
                // app code, which may synchronously set the executing state.
                rotateRecognition()
                onCommand?(text)
            case .stopped:
                rotateRecognition()
                onPartial?("")
                onStop?()
                onStatus?("Stopped · say “Hey Chosen”")
            case .expired:
                onPartial?("")
                onStatus?("Say “Hey Chosen”")
            }
        }
    }

    private func rotateRecognition() {
        guard isRunning, recoveryTask == nil else { return }
        do {
            try beginRecognition(preservingPending: true)
        } catch {
            recover(rebuildAudio: false)
        }
    }

    /// Recognition may stop at its duration limit or after prolonged silence.
    /// Bounded backoff avoids a failure loop; route changes rebuild the input tap.
    private func recover(rebuildAudio: Bool, quiet: Bool = false) {
        guard isRunning else { return }
        if rebuildAudio {
            // A disconnected microphone can truncate a sentence. Keep the command
            // window open, but require the user to repeat its unfinished contents.
            session.beginRecognition(preservingPending: false)
            onPartial?("")
        }
        if recoveryTask != nil {
            // A route notification must still replace the obsolete engine even if
            // a recognizer retry was already scheduled.
            if rebuildAudio { endAudioEngine() }
            return
        }
        endRecognition()
        if rebuildAudio { endAudioEngine() }
        if !quiet { onStatus?(rebuildAudio ? "Reconnecting microphone…" : "Restarting local speech…") }
        let expectedLifecycle = lifecycle
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while self.isRunning && self.lifecycle == expectedLifecycle && !Task.isCancelled {
                let delay = quiet && self.recoveryAttempts == 0 ? 0.05 : min(4.0, 0.25 * pow(2, Double(self.recoveryAttempts)))
                try? await Task.sleep(for: .seconds(delay))
                guard self.isRunning, self.lifecycle == expectedLifecycle, !Task.isCancelled else { return }
                do {
                    if self.engine == nil { try self.startAudioEngine() }
                    try self.beginRecognition(preservingPending: true)
                    self.recoveryTask = nil
                    self.onStatus?(self.session.isExecuting ? "Working · say “stop” to interrupt" : self.session.isActive ? "Listening…" : "Say “Hey Chosen”")
                    return
                } catch {
                    self.recoveryAttempts += 1
                    if self.recoveryAttempts >= 6 {
                        let message = error.localizedDescription
                        self.stop()
                        self.onStatus?(message)
                        return
                    }
                }
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

    private static func speechAuthorization() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        default: return false
        }
    }
}

/// The audio-render thread never touches actor-isolated application state.
/// A short lock protects request swaps and the latest meter snapshot.
private final class VoiceAudioRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var rms = 0.0
    private var lastSpeechAt: TimeInterval = 0

    func setRequest(_ next: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock()
        let previous = request
        request = next
        previous?.endAudio()
        lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        var energy = 0.0
        if let channels = buffer.floatChannelData, buffer.frameLength > 0 {
            let samples = channels[0]
            for index in 0..<Int(buffer.frameLength) {
                let value = Double(samples[index])
                energy += value * value
            }
            energy = sqrt(energy / Double(buffer.frameLength))
        }
        lock.lock()
        rms = energy
        // Conservative acoustic gate; transcript changes also reset the endpoint
        // timer, so quieter speech still gets a complete 700 ms trailing window.
        if energy > 0.008 { lastSpeechAt = ProcessInfo.processInfo.systemUptime }
        request?.append(buffer)
        lock.unlock()
    }

    func meter() -> (rms: Double, lastSpeechAt: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        return (rms, lastSpeechAt)
    }

    func resetMeter() {
        lock.lock()
        rms = 0
        lastSpeechAt = ProcessInfo.processInfo.systemUptime
        lock.unlock()
    }
}
