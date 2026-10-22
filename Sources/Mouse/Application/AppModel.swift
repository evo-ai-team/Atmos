import AppKit
import Combine
import ServiceManagement
import AVFoundation
#if SWIFT_PACKAGE
import MouseCore
#endif

struct Activity: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

/// Main-actor coordinator for voice, accepted goals, and the execution loop.
/// Speech screening has its own lifetime; only accepted input can replace work.
/// Screen capture, selection diagnostics, and disk storage live in focused types.
@MainActor
final class AppModel: ObservableObject {
    @Published var listening = false
    @Published var working = false
    @Published var active = false
    @Published var voiceAuthorized = false
    @Published var status = "Waiting for Hey Mouse"
    @Published var transcript = ""
    @Published var command = ""
    @Published var error: String?
    @Published var activity: [Activity] = []
    @Published private(set) var answers: [QuestionAnswer] = []
    @Published private(set) var actionHistory = ActionHistory()
    @Published private(set) var timingTraces: [PipelineTiming] = []
    @Published private(set) var latestCommandTiming: PipelineTiming?
    @Published var preferences = MousePreferences.load() {
        didSet {
            preferences.save()
            applyVoicePreferences()
        }
    }
    @Published private(set) var latestDecision = "No action selected this session"
    @Published private(set) var latestDispatch = "No input dispatched this session"
    @Published private(set) var lastActionTargets: [DecisionChoice] = []
    @Published private(set) var lastActionTreeSummary = "No action selected this session"
    @Published var hasKey = false
    @Published var hasSavedKey = false
    @Published var screenAllowed = false
    @Published var accessibilityAllowed = false
    @Published var budget = DemoBudget()
    @Published var usageWarning: String?
    @Published private(set) var lastAcceptedGoal: String?
    @Published var launchAtLogin = false
    @Published private(set) var startingVoice = false
    let computer = NativeComputer()
    let voice = VoiceInput()
    private let accessibility = AccessibilityController()
    private lazy var screenObserver = ScreenObserver(computer: computer, accessibility: accessibility)
    // Execution and incoming selection have separate lifetimes. The chosen
    // model must accept new speech before it can retire an existing task.
    // `generation` owns UI/state changes as well as input: a cancelled request
    // may still return, but it must never dispatch or finish its replacement.
    private var runningTask: Task<Void, Never>?
    private var generation = UUID()
    private var conversationContext = CommandContext()
    private var currentHistoryEntryID: UUID?
    private var speculativeCapture: PendingCapture?
    private var taskState: TaskSteeringState?
    private var pendingInputs: [String] = []
    private var taskPausedForUser = false
    private var taskClarification: String?
    private var retiredWork: Task<Void, Never>?
    // A trace follows one utterance through replay, screening, and execution.
    // Async work captures its own reference so an old response cannot record
    // time against a newer command. The UI retains only the ten latest traces.
    private var voiceTimings: [UUID: PipelineTiming] = [:]
    private var screeningTiming: PipelineTiming?
    private var runningTiming: PipelineTiming?
    private var submittedBehaviors: [UUID: ChatbotBehavior] = [:]
    private var screeningCaptureID: UUID?
    private var preparedInput: PreparedInput?
    private var executionRevision = 0
    private var inputInFlight = false
    private var currentBehavior: ChatbotBehavior = .decisionsTextOnly
    private lazy var speechScreening = SpeechScreeningQueue(
        check: { [weak self] text in
            guard let self else { throw CancellationError() }
            return try await self.screenUtterance(text)
        },
        onAccepted: { [weak self] command, captureID in
            guard let self else { return }
            let timing = self.screeningTiming
            self.screeningTiming = nil
            let prepared = self.preparedInput
            self.preparedInput = nil
            if let timing { self.submittedBehaviors.removeValue(forKey: timing.id) }
            if let captureID { self.voiceTimings.removeValue(forKey: captureID) }
            // Answers are handled before accepting a new computer task. They
            // must not cancel ongoing input, change its goal, or claim it is done.
            if let answer = prepared?.turn.answer {
                timing?.mark("Question answered without desktop input")
                timing?.finish(.succeeded)
                self.receiveAnswer(answer, to: command)
                return
            }
            // Only model-accepted speech may retire work. Keep accepted fragments
            // until the execution model incorporates them into its complete goal.
            self.pendingInputs.append(command)
            self.latestCommandTiming = timing
            timing?.mark("Command accepted")
            self.launchTask(captureID: captureID, timing: timing, prepared: prepared)
        },
        onIgnored: { [weak self] captureID in
            self?.finishSpeechScreening(captureID: captureID)
        },
        onFailure: { [weak self] error, captureID in
            guard let self else { return }
            self.finishSpeechScreening(captureID: captureID)
            self.error = error.localizedDescription
            self.log(error.localizedDescription, detail: "Command selection failed")
            if !self.working {
                self.status = "Command not accepted · try again"
                self.showNotice("Couldn't check command · try again")
            }
        },
        onCheckStarted: { [weak self] captureID, timing in
            self?.screeningCaptureID = captureID
            self?.screeningTiming = timing
        }
    )

    private struct PendingCapture {
        let id: UUID
        let generation: UUID
        let task: Task<ScreenObservation, Error>
    }
    private var previousApplication: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private let notch = MouseNotchController()
    private var noticeTask: Task<Void, Never>?
    private var started = false
    private var usageHistory = UsageHistory()

    // TESTING BEGIN: opt-in diagnostics; never persisted or started automatically.
    @Published private(set) var benchmarkEnabled = false
    @Published private(set) var benchmarkTrialInProgress = false
    @Published private(set) var benchmarkRequestCount = 0
    @Published private(set) var benchmarkStatus: String?
    @Published private(set) var benchmarkExportDirectory: URL?
    @Published private(set) var benchmarkLatestResultURL: URL?
    private var benchmarkRecorder: BenchmarkRecorder?
    private var benchmarkPriorVoiceState: (listening: Bool, active: Bool)?
    private var benchmarkOriginalContext: CommandContext?

    func setBenchmarkEnabled(_ enabled: Bool) {
        guard enabled != benchmarkEnabled else { return }
        if enabled {
            guard !working, !speechScreening.isScreening, !startingVoice,
                  taskState == nil, benchmarkRecorder?.isRunning != true else {
                benchmarkStatus = "Stop the current task before enabling benchmarks."
                return
            }
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Mouse/Benchmarks", isDirectory: true)
            do { benchmarkRecorder = try BenchmarkRecorder(directory: directory) }
            catch { benchmarkStatus = "Could not create the benchmark export folder."; return }
            benchmarkPriorVoiceState = (voice.isEnabled, active)
            benchmarkOriginalContext = conversationContext
            benchmarkEnabled = true
            benchmarkRequestCount = 0
            benchmarkExportDirectory = directory
            voice.stop()
            listening = false
            active = false
            benchmarkStatus = "Ready · microphone paused"
        } else {
            benchmarkEnabled = false
            if benchmarkRecorder?.isRunning == true {
                benchmarkStatus = "Stopping trial and saving results…"
                benchmarkRecorder?.noteStop(.disabled)
                cancel(silent: true)
            } else {
                benchmarkRecorder = nil
                benchmarkOriginalContext = nil
                restoreBenchmarkMicrophone()
                benchmarkStatus = "Off"
            }
        }
    }

    func stopBenchmarkTrial() {
        guard benchmarkRecorder?.isRunning == true else { return }
        benchmarkStatus = "Stopping trial and saving results…"
        benchmarkRecorder?.noteStop(.manualStop)
        cancel(silent: true)
    }

    private func restoreBenchmarkMicrophone() {
        guard let previous = benchmarkPriorVoiceState else { return }
        benchmarkPriorVoiceState = nil
        if previous.listening { startVoice(activate: previous.active) }
    }

    private func beginBenchmarkTrial(timing: PipelineTiming, command: String) -> Bool {
        guard benchmarkEnabled, let recorder = benchmarkRecorder else { return true }
        do {
            try recorder.begin(timing: timing, command: command, behavior: preferences.behavior.title,
                               budget: budget, firstActionIndex: actionHistory.entries.count,
                               startingContextEntryCount: conversationContext.entries.count,
                               onDeadline: { [weak self] in self?.cancel(silent: true) },
                               onFinished: { [weak self] in await self?.finishBenchmarkTrial() })
            benchmarkTrialInProgress = true
            benchmarkStatus = "Running · 30-second limit"
            return true
        } catch {
            timing.finish(.failed)
            benchmarkStatus = "Benchmark session limit reached. Disable and enable to start a new session."
            return false
        }
    }

    private func finishBenchmarkTrial() async {
        guard let recorder = benchmarkRecorder, let trial = recorder.trial else { return }
        // Drain cancelled input first; late cleanup cannot change frozen timings
        // but can still release a key/button and settle the action's status.
        if taskState != nil { cancel(silent: true) } // Clear paused test goals before another trial.
        await retiredWork?.value
        if let original = benchmarkOriginalContext { conversationContext = original }
        currentHistoryEntryID = nil
        do {
            benchmarkLatestResultURL = try recorder.finish(actions: actionHistory.entries, budget: budget)
            benchmarkStatus = "Saved · " + trial.timing.snapshot.outcome.rawValue
        } catch { benchmarkStatus = "Export failed; timings remain in Settings." }
        benchmarkTrialInProgress = false
        benchmarkRequestCount = recorder.session.requestCount
        if !benchmarkEnabled {
            benchmarkRecorder = nil
            benchmarkOriginalContext = nil
            restoreBenchmarkMicrophone()
        }
        // Export and focus changes happen only after the measured trace ends.
        NSApp.activate()
        for window in NSApp.windows where window.canBecomeMain || window.canBecomeKey {
            window.makeKeyAndOrderFront(nil)
        }
    }
    // TESTING END


    // MARK: - Initialization and voice events

    init() {
        applyVoicePreferences()
        let usage = usageHistory.load()
        budget = usage.budget
        usageWarning = usage.warning
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        observeForegroundApplication()
        connectVoiceCallbacks()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
    }

    private func observeForegroundApplication() {
        previousApplication = NSWorkspace.shared.frontmostApplication
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.previousApplication = app }
        }
    }

    private func connectVoiceCallbacks() {
        voice.onCommand = { [weak self] text in self?.submit(text) }
        voice.onTimingStarted = { [weak self] id, timing in
            guard let self else { return }
            self.voiceTimings[id] = timing
            self.retainTiming(timing)
        }
        voice.onFinalizationStarted = { [weak self] id in self?.startSpeculativeCapture(id) }
        voice.onFinalizationInvalidated = { [weak self] id in
            self?.invalidateSpeculativeCapture(id)
            self?.voiceTimings.removeValue(forKey: id)
        }
        voice.onFinalizedCommand = { [weak self] text, id in self?.submit(text, captureID: id) }
        voice.onPartial = { [weak self] text in
            guard let self else { return }
            // Unclassified speech must not interrupt work or replace its action
            // label. Idle users still get live text before the separate check.
            guard !self.working else { return }
            if text.isEmpty, self.speechScreening.isScreening { return }
            guard self.transcript != text else { return }
            self.transcript = text
            self.noticeTask?.cancel()
            if self.active { self.notch.show(text.isEmpty ? .active : .transcribing(text)) }
        }
        voice.onStatus = { [weak self] state in
            guard let self else { return }
            self.listening = self.voice.isEnabled
            if !self.working { self.status = state }
        }
        voice.onActivationChanged = { [weak self] active in
            guard let self else { return }
            self.active = active
            self.noticeTask?.cancel()
            if !self.working { self.showRestingState() }
        }
        voice.onDeactivation = { [weak self] in
            guard let self else { return }
            self.cancel(silent: true)
            self.transcript = ""
            self.status = "Waiting for Hey Mouse"
            self.showRestingState()
        }
        voice.onFailure = { [weak self] message in
            guard let self else { return }
            self.cancel(silent: true)
            self.listening = false
            self.error = message
            self.status = "Voice needs attention"
            self.log(message, detail: "Voice stopped")
            self.showNotice("Voice paused · check Mouse settings")
        }
    }

    // MARK: - Settings and voice controls

    private func applyVoicePreferences() {
        voice.audioSensitivity = preferences.audioSensitivity
        voice.secondPassEnabled = preferences.secondPassEnabled
    }

    func refreshPermissions() {
        // This periodic main-actor work can delay an in-flight command even
        // though it is not one of its API calls. Attribute the shared interval
        // to each affected trace without adding it to their elapsed totals.
        var seen: Set<UUID> = []
        let timings = ([runningTiming, screeningTiming].compactMap { $0 } + Array(voiceTimings.values))
            .filter { seen.insert($0.id).inserted }
        let spans = timings.map { ($0, $0.begin("Background permission and Keychain refresh")) }
        defer { for (timing, span) in spans { timing.end(span) } }
        hasSavedKey = KeychainStore.exists()
        hasKey = (try? KeychainStore.load()) != nil
        screenAllowed = computer.screenRecordingGranted
        accessibilityAllowed = computer.accessibilityGranted
        listening = voice.isEnabled
        voiceAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var needsSetup: Bool { !hasKey || !screenAllowed || !accessibilityAllowed || !voiceAuthorized }

    /// Launch into local wake-word monitoring without opening a main window.
    func startStandby() {
        guard !started else { return }
        started = true
        refreshPermissions()
        if voiceAuthorized { startVoice() }
    }

    func toggleListening() {
        if listening {
            cancel(silent: true)
            voice.stop()
            listening = false
            active = false
            status = "Microphone paused"
            transcript = ""
            notch.hide()
            return
        }
        startVoice()
    }

    private func startVoice(activate: Bool = false) {
        // TESTING BEGIN: no speech may contaminate a bounded typed trial.
        guard !benchmarkEnabled, !benchmarkTrialInProgress else { return }
        // TESTING END
        guard !startingVoice else { return }
        startingVoice = true
        status = "Preparing voice…"
        Task {
            defer {
                startingVoice = false
                refreshPermissions()
            }
            do {
                if !voice.isRunning { try await voice.start() }
                listening = voice.isEnabled
                error = nil
                if activate { voice.activate() }
                else { showRestingState() }
            } catch {
                self.error = error.localizedDescription
                listening = false
                status = "Voice needs attention"
                showNotice("Voice setup needs attention")
            }
        }
    }

    func listenNow() { startVoice(activate: true) }

    func sleep() {
        voice.deactivate()
        active = false
        cancel(silent: true)
        transcript = ""
        showRestingState()
    }

    func requestScreen() {
        _ = computer.requestScreenRecordingPermission()
        refreshPermissions()
    }

    func requestAccessibility() {
        _ = computer.requestAccessibilityPermission()
        refreshPermissions()
    }

    func saveKey(_ key: String) {
        do {
            try KeychainStore.save(key)
            refreshPermissions()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
    func reconnectKey() {
        do {
            try KeychainStore.authorizeSavedKey()
            refreshPermissions()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { self.error = error.localizedDescription }
    }

    // MARK: - Speech screening and speculative capture

    /// Called at the speech endpoint: the accurate second recognizer and capture
    /// run independently. A revision invalidates this exact candidate.
    private func startSpeculativeCapture(_ id: UUID) {
        invalidateSpeculativeCapture()
        guard active, !working, !speechScreening.isScreening, screenAllowed, accessibilityAllowed,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let token = generation
        let retirement = retiredWork
        let timing = voiceTimings[id]
        let task = Task {
            let wait = timing?.begin("Speculative capture: cancelled input cleanup")
            await retirement?.value
            timing?.end(wait, outcome: Task.isCancelled ? .cancelled : .succeeded)
            try Task.checkCancellation()
            self.computer.resetDisplay()
            return try await self.measureStage(timing, "Speculative observation") {
                try await self.screenObserver.capture(timing: timing)
            }
        }
        speculativeCapture = PendingCapture(id: id, generation: token, task: task)
    }

    private func invalidateSpeculativeCapture(_ id: UUID? = nil) {
        guard let pending = speculativeCapture, id == nil || pending.id == id else { return }
        pending.task.cancel()
        speculativeCapture = nil
    }

    func submit(_ value: String? = nil, captureID: UUID? = nil) {
        let text = (value ?? command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if VoiceControl.match(text) != nil {
            sleep()
            return
        }
        // TESTING BEGIN: keep one trial and its terminal export isolated.
        if benchmarkRecorder?.isRunning == true || (benchmarkEnabled && captureID != nil) {
            benchmarkStatus = "Wait for this trial or use Stop trial."
            return
        }
        // TESTING END
        command = ""
        // The queue takes ownership now; replay associations are independent of
        // the ten-report UI limit and are needed only until this handoff.
        // TESTING BEGIN: larger bounded diagnostics only for opt-in trials.
        let timing = captureID.flatMap { voiceTimings.removeValue(forKey: $0) }
            ?? (benchmarkEnabled ? PipelineTiming(origin: .typed, maximumRecords: 2_048, maximumAnnotations: 512)
                : PipelineTiming(origin: .typed))
        retainTiming(timing)
        guard beginBenchmarkTrial(timing: timing, command: text) else { return }
        // TESTING END
        submittedBehaviors[timing.id] = preferences.behavior
        timing.annotate("Chatbot behavior: \(preferences.behavior.title)")
        timing.mark("Command submitted for intent and action selection")
        speechScreening.enqueue(text, captureID: captureID, timing: timing)
        if !working {
            transcript = ""
            noticeTask?.cancel()
            status = "Checking command…"
            notch.show(.thinking)
        }
    }

    /// The first selected model checks intent and prepares the first action in the
    /// same request. Background speech can be ignored without cancelling ongoing
    /// input; only an accepted result is transferred to the execution lifetime.
    private func screenUtterance(_ text: String) async throws -> String? {
        guard let timing = screeningTiming else { throw CancellationError() }
        let behavior = submittedBehaviors[timing.id] ?? preferences.behavior
        let captureID = screeningCaptureID
        preparedInput = nil
        try Task.checkCancellation()
        // A previously cancelled drag may still be releasing its button. Never
        // ground a new action in an observation taken before that cleanup ends.
        let retirement = retiredWork
        await measureStage(timing, "Incoming command: cancelled input cleanup") {
            await retirement?.value
        }
        try Task.checkCancellation()
        let key = try measureStage(timing, "Command permissions and API key") { try executionKey() }
        let revision = executionRevision
        let inputWasInFlight = inputInFlight
        let wasWorking = working
        let history = SelectionHistory(full: conversationContext.text, commands: conversationContext.entries)
        let input = (pendingInputs + [text]).joined(separator: "\n")
        let observation: ScreenObservation
        // An independent AX owner prevents a background utterance's capture from
        // replacing the retained handles being used by an accepted task.
        let controller = wasWorking ? AccessibilityController() : accessibility
        if wasWorking {
            let observer = ScreenObserver(computer: computer, accessibility: controller)
            observation = try await measureStage(timing, "Incoming command observation") {
                try await observer.capture(timing: timing)
            }
        } else {
            let pendingCapture = speculativeCapture
            speculativeCapture = nil
            let prefetched = pendingCapture.flatMap { $0.id == captureID ? $0 : nil }
            if let pendingCapture, prefetched == nil {
                // A typed command can arrive during another utterance's replay.
                // Drain that capture before reusing the AX controller, otherwise
                // its late result could replace this command's retained handles.
                pendingCapture.task.cancel()
                await measureStage(timing, "Discard unrelated speculative observation") {
                    _ = await pendingCapture.task.result
                }
                try Task.checkCancellation()
            }
            defer { prefetched?.task.cancel() }
            observation = try await measureStage(timing, "Initial observation") {
                try await initialObservation(prefetched: prefetched, captureID: captureID,
                                             previousGeneration: generation, token: generation, timing: timing)
            }
        }
        // TESTING BEGIN: references only; encoding and disk writes follow completion.
        benchmarkRecorder?.captureFirst(observation, timing: timing)
        // TESTING END
        var (selection, turn) = try await measureStage(timing, "Initial intent and action selection") {
            try await chooseNextAction(input: input, newInput: true, history: history,
                                       observation: observation, selector: DecisionsClient(apiKey: key),
                                       generator: OpenAIComputerClient(apiKey: key), behavior: behavior,
                                       token: nil, timing: timing, publish: false)
        }
        try Task.checkCancellation()
        guard !turn.ignored else { return nil }
        selection.accessibilityController = controller
        preparedInput = PreparedInput(input: input, behavior: behavior, observation: observation,
                                      selection: selection, turn: turn, executionRevision: revision,
                                      reusable: !inputWasInFlight)
        return text
    }

    private func finishSpeechScreening(captureID: UUID?) {
        if let timing = screeningTiming { submittedBehaviors.removeValue(forKey: timing.id) }
        screeningTiming = nil
        preparedInput = nil
        if let captureID { voiceTimings.removeValue(forKey: captureID) }
        if let captureID { invalidateSpeculativeCapture(captureID) }
        guard !working else { return }
        // A new utterance can be arriving while the preceding check completes.
        // Preserve those live words; otherwise quietly return to the active notch.
        if !voice.hasUncommittedSpeech {
            transcript = ""
            status = active ? "Ready for your next command" : "Waiting for Hey Mouse"
            showRestingState()
        }
    }

    // MARK: - Task lifetime and observation

    /// Wait for cancelled input cleanup before taking a replacement screenshot.
    /// An interrupted drag must release its button before the next task can act.
    private func retireCurrentWork(outcome: PipelineTiming.Outcome = .superseded) {
        actionHistory.markUnfinishedUncertain(executionID: generation)
        generation = UUID()
        runningTiming?.finish(outcome)
        runningTiming = nil
        guard let old = runningTask else { return }
        old.cancel()
        let prior = retiredWork
        retiredWork = Task {
            await prior?.value
            await old.value
        }
        runningTask = nil
    }

    private func launchTask(captureID: UUID? = nil, timing suppliedTiming: PipelineTiming? = nil,
                            prepared: PreparedInput? = nil) {
        guard !pendingInputs.isEmpty || taskState != nil else {
            working = false
            voice.setExecuting(false)
            showRestingState()
            return
        }
        let timing = suppliedTiming ?? PipelineTiming(origin: .continued)
        retainTiming(timing)
        latestCommandTiming = timing
        let behavior = prepared?.behavior ?? currentBehavior
        currentBehavior = behavior
        if suppliedTiming == nil { timing.annotate("Chatbot behavior: \(behavior.title)") }
        let reusable = prepared.flatMap {
            $0.reusable && !inputInFlight && $0.executionRevision == executionRevision
                && $0.input == pendingInputs.joined(separator: "\n") ? $0 : nil
        }
        let setup = timing.begin("Execution setup and presentation")
        // Transfer the capture before retiring the previous generation.
        let prefetched = speculativeCapture.flatMap { $0.id == captureID ? $0 : nil }
        if prefetched != nil { speculativeCapture = nil }
        let previousGeneration = generation
        retireCurrentWork()
        runningTiming = timing
        taskState?.markUnfinishedActionsUncertain()
        invalidateSpeculativeCapture()
        noticeTask?.cancel()
        let hasNewInput = !pendingInputs.isEmpty
        let (text, history) = measureStage(timing, "Prepare command and session history") {
            let text = hasNewInput ? pendingInputs.joined(separator: "\n")
                : "Continue the already accepted active task from its recorded progress and the current screen."
            return (text, SelectionHistory(full: conversationContext.text, commands: conversationContext.entries))
        }
        let retirement = retiredWork
        command = ""
        transcript = ""
        error = nil
        let token = UUID()
        generation = token
        working = true
        status = "Thinking…"
        voice.setExecuting(true)
        notch.show(.thinking)
        timing.end(setup)
        runningTask = Task {
            defer { prefetched?.task.cancel() }
            do {
                let cleanup = timing.begin("Wait for cancelled input cleanup")
                await retirement?.value
                timing.end(cleanup, outcome: Task.isCancelled ? .cancelled : .succeeded)
                try checkCurrentTask(token)
                let key = try measureStage(timing, "Execution permissions and API key") { try executionKey() }
                let observation: ScreenObservation
                if let reusable {
                    observation = reusable.observation
                    try screenObserver.validate(observation)
                    timing.mark("Reused accepted model turn and observation")
                } else {
                    if prepared != nil { timing.mark("Task progressed during selection; refresh accepted command") }
                    observation = try await measureStage(timing, "Initial observation") {
                        try await initialObservation(
                            prefetched: prefetched, captureID: captureID,
                            previousGeneration: previousGeneration, token: token, timing: timing)
                    }
                }
                try await runCommand(text, hasNewInput: hasNewInput, history: history,
                                     key: key, observation: observation, behavior: behavior,
                                     prepared: reusable, token: token, timing: timing)
            } catch is CancellationError {
                timing.finish(.cancelled)
                // A replacement owns its own history and UI; retired tasks cannot
                // finish or overwrite the new command's entry.
                guard generation == token else { return }
                finishHistory(status: .stopped, outcome: "Stopped before completion. Earlier actions may already have taken effect.")
                finishTask(token, outcome: .cancelled)
            } catch {
                timing.finish(.failed)
                guard generation == token else { return }
                finishHistory(status: .failed, outcome: error.localizedDescription + " Completion was not confirmed; earlier actions may already have taken effect.")
                self.error = error.localizedDescription
                status = "Paused"
                log(error.localizedDescription, detail: "Needs attention")
                finishTask(token, outcome: .failed)
                showNotice("Paused · check Mouse settings")
            }
        }
    }

    private func executionKey() throws -> String {
        guard screenAllowed else {
            throw MouseError.permission("Allow Screen Recording in Mouse Settings to see the app you want to control.")
        }
        guard accessibilityAllowed else {
            throw MouseError.permission("Allow Accessibility in Mouse Settings to click and type.")
        }
        guard let key = try KeychainStore.load() else {
            throw MouseError.configuration("Add your OpenAI API key in Settings.")
        }
        return key
    }

    private func initialObservation(prefetched: PendingCapture?, captureID: UUID?,
                                    previousGeneration: UUID, token: UUID, timing: PipelineTiming) async throws -> ScreenObservation {
        var restoredFocus = false
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            try await measureStage(timing, "Restore foreground app and wait 220 ms") {
                previousApplication?.activate(options: [])
                try await Task.sleep(for: .milliseconds(220))
            }
            restoredFocus = true
        }
        measureStage(timing, "Hide Mouse windows") {
            for window in NSApp.windows where window.isVisible && (window.canBecomeMain || window.canBecomeKey) {
                window.orderOut(nil)
            }
        }

        // Restoring focus invalidates the prefetch even if its age and utterance
        // still match: the observation must describe the app we are about to use.
        if let prefetched, let captureID, !restoredFocus {
            let wait = timing.begin("Wait for speculative observation")
            let result = await withTaskCancellationHandler {
                await prefetched.task.result
            } onCancel: {
                prefetched.task.cancel()
            }
            timing.end(wait, outcome: Task.isCancelled ? .cancelled : .succeeded)
            try checkCurrentTask(token)
            if case let .success(observation) = result {
                let stamp = CaptureStamp(utteranceID: prefetched.id, generation: prefetched.generation,
                                         processID: observation.processID, capturedAt: observation.capturedAt)
                if stamp.canReuse(utteranceID: captureID, generation: previousGeneration,
                                  processID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                                  now: ProcessInfo.processInfo.systemUptime),
                   (try? screenObserver.validate(observation)) != nil {
                    timing.mark("Reused speculative observation")
                    return observation
                }
            }
            timing.mark("Speculative observation unusable: capture again")
        }
        if restoredFocus, prefetched != nil { timing.mark("Focus restore invalidated speculative observation") }
        computer.resetDisplay()
        let observation = try await screenObserver.capture(timing: timing)
        try checkCurrentTask(token)
        return observation
    }

    // MARK: - Observe, choose, and dispatch

    /// Freeze prior history before accepting the new command. The selector gets
    /// a compact projection; the planner retains the complete context if needed.
    private struct SelectionHistory {
        let full: String
        let commands: [CommandContext.Entry]
    }

    /// A model's acceptance and chosen operation travel together. If an older
    /// task dispatched while selection was pending, its changed UI invalidates
    /// this operation; a fresh selection is required before any new input.
    private struct PreparedInput {
        let input: String
        let behavior: ChatbotBehavior
        let observation: ScreenObservation
        let selection: SelectedAction
        let turn: ModelTurn
        let executionRevision: Int
        let reusable: Bool
    }

    private func runCommand(_ text: String, hasNewInput: Bool, history: SelectionHistory,
                            key: String, observation initial: ScreenObservation, behavior: ChatbotBehavior,
                            prepared: PreparedInput?, token: UUID, timing: PipelineTiming) async throws {
        let selector = DecisionsClient(apiKey: key)
        let generator = OpenAIComputerClient(apiKey: key)
        var observation = initial
        var step = 0
        var firstTurn = true
        while true {
            try checkCurrentTask(token)
            status = "Choosing the next action…"
            notch.show(.thinking)
            let newInput = firstTurn && hasNewInput
            let input = newInput ? text : (taskState?.goal ?? text)
            let (selection, turn) = try await measureStage(timing, "Step \(step + 1): choose action") {
                if firstTurn, let prepared { return (prepared.selection, prepared.turn) }
                return try await chooseNextAction(
                    input: input, newInput: newInput, history: history, observation: observation,
                    selector: selector, generator: generator, behavior: behavior, token: token, timing: timing)
            }
            latestDecision = selection.decisionSummary
            let native = selection.nativeTarget
            // Raw speech and an in-flight text check do not invalidate this
            // response. A confirmed redirect or immediate Stop changes its token.
            try checkCurrentTask(token)
            if turn.ignored {
                timing.finish(.ignored)
                finishIgnoredTurn(newInput: newInput, token: token)
                return
            }
            if let answer = turn.answer {
                // A stale prepared action can be reclassified as a question on
                // refresh. Restore any prior task before publishing the answer.
                timing.finish(.succeeded)
                pendingInputs.removeAll()
                if taskState != nil, !taskPausedForUser {
                    launchTask()
                } else {
                    finishTask(token, keepingTask: taskState != nil)
                }
                receiveAnswer(answer, to: text)
                return
            }
            if newInput {
                measureStage(timing, "Accept task update") {
                    acceptInput(text, selection: selection, turn: turn)
                }
            }
            firstTurn = false
            if let reason = turn.pauseReason {
                error = reason
                status = "Needs your input"
                finishHistory(status: .paused, outcome: reason)
                taskPausedForUser = true
                taskClarification = reason
                log(reason, detail: "Needs your input")
                finishTask(token, keepingTask: true, outcome: .paused)
                showNotice(reason, duration: 12)
                return
            }
            if turn.calls.isEmpty {
                completeCommand(outcome: turn.message.isEmpty ? "Done" : turn.message, token: token)
                return
            }
            let actions = turn.calls.flatMap(\.actions)
            guard !actions.isEmpty, actions.count <= 12 else { throw MouseError.invalidAction("The model returned an empty or oversized action batch.") }
            // TESTING BEGIN: allow terminal review after batch six; block batch seven before dispatch.
            if let recorder = benchmarkRecorder, recorder.isRunning {
                try recorder.checkBatch(timing: timing, completed: step)
            }
            // TESTING END
            try measureStage(timing, "Step \(step + 1): validate observation and actions") {
                try screenObserver.validate(observation)
                if native == nil {
                    for action in actions { try computer.validateAction(action, frame: observation.frame) }
                }
            }
            for call in turn.calls {
                let dispatchSummary = try await measureStage(timing, "Step \(step + 1): dispatch input") {
                    try await dispatch(call, selection: selection, observation: observation, token: token, timing: timing)
                }
                // Let the interface settle before taking a fresh image/tree pair.
                // This suspension is cancellable: Stop interrupts it immediately.
                try await measureStage(timing, "Step \(step + 1): interface settle wait (1000 ms)") {
                    try await Task.sleep(for: .milliseconds(1_000))
                }
                try checkCurrentTask(token)
                observation = try await measureStage(timing, "Step \(step + 1): post-action observation") {
                    try await screenObserver.capture(timing: timing)
                }
                try checkCurrentTask(token)
                // TESTING: retain the latest existing capture; no extra observation or disk work.
                benchmarkRecorder?.captureLatest(observation, timing: timing)
                log(call.description,
                    detail: "Step \(step + 1) · \(selection.route) · \(selection.choiceSummary)\n\(dispatchSummary)")
            }
            step += 1
            try checkCurrentTask(token)
            // Every next step uses this command's frozen behavior and a fresh
            // observation, never an unobserved plan for the rest of a task.
        }
    }

    /// Selection and optional generation form one turn; both remain cancellable
    /// before any accepted-goal or dispatch state is changed.
    private func chooseNextAction(input: String, newInput: Bool, history: SelectionHistory,
                                  observation: ScreenObservation, selector: DecisionsClient,
                                  generator: OpenAIComputerClient, behavior: ChatbotBehavior,
                                  token: UUID?, timing: PipelineTiming, publish: Bool = true) async throws -> (SelectedAction, ModelTurn) {
        // Freeze all semantic context before awaiting either endpoint: ongoing
        // accepted work may continue while this new utterance is being assessed.
        let task = taskState
        let clarification = taskPausedForUser ? taskClarification : nil
        if !behavior.usesDecisions {
            try recordRequestStarted(timing: timing) // TESTING: opt-in request cap
            let turn = try await measureStage(timing, "Luna intent and action generation") {
                try await generator.begin(command: input, frame: observation.frame, context: history.full,
                                          activeTask: task?.contextText ?? "", pendingClarification: clarification,
                                          accessibility: observation.accessibility.contextText,
                                          continuingTask: !newInput, timing: timing)
            }
            try checkSelectionLifetime(token)
            recordUsage(turn, timing: timing)
            let selection = SelectedAction(lunaTurn: turn, tree: observation.accessibility)
            if publish { latestDecision = selection.decisionSummary }
            timing.mark("Selected route: \(selection.route)")
            // TESTING: include answer/ignore/completion routes even without actions.
            benchmarkRecorder?.recordRoute(selection.route, timing: timing)
            return (selection, turn)
        }
        // Classify a new amendment beside the action in the same request.
        // Known native targets remain usable; only an unresolved relationship
        // needs the generator to rewrite the combined intent before acting.
        let (options, contextText) = try measureStage(timing, "Prepare action choices and decision context") {
            let classifiesAmendment = newInput && task != nil
            let context = ComputerDecisionContext(
                request: input, isContinuation: !newInput, task: task,
                recentCommands: history.commands,
                pendingClarification: clarification,
                snapshot: observation.accessibility
            )
            let options = ComputerDecisionOptions(snapshot: observation.accessibility,
                                              allowNativeActions: true,
                                              allowCompletion: behavior.decisionsUseScreenshot || context.hasUIEvidence,
                                              allowIgnore: newInput,
                                              classifyTaskRelationship: classifiesAmendment,
                                              includesScreenshot: behavior.decisionsUseScreenshot)
            let contextText = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
            return (options, contextText)
        }
        try recordRequestStarted(timing: timing) // TESTING: opt-in request cap
        let decision = try await measureStage(timing, "Decisions selection") {
            try await selector.decide(instructions: ComputerDecisionOptions.instructions(includesScreenshot: behavior.decisionsUseScreenshot),
                                     context: contextText,
                                     questions: options.questions, frame: behavior.decisionsUseScreenshot ? observation.frame : nil, timing: timing)
        }
        try checkSelectionLifetime(token)
        budget.record(inputTokens: decision.inputTokens, outputTokens: decision.outputTokens, rate: .decisions)
        persistUsage(timing: timing)

        let selection = try measureStage(timing, "Interpret Decisions selection") {
            try SelectedAction(result: decision, options: options, tree: observation.accessibility)
        }
        // Publish selection before generation: even a failed fallback must
        // remain distinguishable from an input that was actually dispatched.
        if publish { latestDecision = selection.decisionSummary }
        timing.mark("Selected route: \(selection.route)")
        // TESTING: include answer/ignore/completion routes even without actions.
        benchmarkRecorder?.recordRoute(selection.route, timing: timing)
        let turn: ModelTurn
        if let immediate = selection.immediateTurn {
            turn = immediate
        } else {
            try recordRequestStarted(timing: timing) // TESTING: opt-in request cap
            turn = try await measureStage(timing, "Responses action generation") {
                try await generator.begin(command: input, frame: observation.frame, context: history.full,
                                             activeTask: task?.contextText ?? "",
                                             pendingClarification: clarification,
                                             accessibility: observation.accessibility.contextText,
                                             continuingTask: !newInput, reviewRequired: selection.operation == .review,
                                             timing: timing)
            }
            try checkSelectionLifetime(token)
            recordUsage(turn, timing: timing)
        }
        return (selection, turn)
    }

    private func checkSelectionLifetime(_ token: UUID?) throws {
        try Task.checkCancellation()
        if let token { try checkCurrentTask(token) }
    }

    private func dispatch(_ call: ComputerCall, selection: SelectedAction,
                          observation: ScreenObservation, token: UUID, timing: PipelineTiming) async throws -> String {
        try checkCurrentTask(token)
        inputInFlight = true
        defer {
            inputInFlight = false
            executionRevision += 1
        }
        // Keep candidates from the actual dispatch attempt. A failed foreground
        // validation must not replace the previous step's offered controls.
        lastActionTargets = selection.offeredTargets
        lastActionTreeSummary = selection.treeSummary
        status = call.description
        notch.show(.working(call.description))
        let native = selection.nativeTarget
        let summary = native.map { ActionDispatchSummary.native(action: $0.action, element: $0.element) }
            ?? ActionDispatchSummary.batch(call.actions)
        latestDispatch = "Sending · \(selection.route)\n\(summary)"
        for action in call.actions {
            try checkCurrentTask(token)
            executionRevision += 1
            let dispatchID = taskState?.beginAction(action: action, description: call.description)
            if let dispatchID {
                // Share the dispatch record's identity: this is the action added
                // to model history, not a separate reconstruction from its label.
                let target = native.map {
                    ActionHistory.NativeTarget(action: $0.action, elementID: $0.element.id,
                                               snapshotID: observation.accessibility.id,
                                               role: $0.element.role, label: $0.element.label,
                                               screenBounds: $0.element.screenBounds)
                }
                actionHistory.begin(id: dispatchID, executionID: token, goal: taskState?.goal ?? "",
                                    source: selection.route, description: call.description,
                                    action: action, nativeTarget: target)
            }
            do {
                if let native {
                    // AX revalidates the exact retained element before acting.
                    // An ambiguous result stops here: do not blindly replay it
                    // as a click, since the first action may have taken effect.
                    try await (selection.accessibilityController ?? accessibility).perform(action: native.action, targetID: native.element.id,
                                                    snapshotID: observation.accessibility.id,
                                                    processID: observation.processID, timing: timing)
                } else {
                    try await computer.execute(action, frame: observation.frame, timing: timing)
                }
                try checkCurrentTask(token)
            } catch {
                if let dispatchID {
                    actionHistory.markUncertain(id: dispatchID, detail: error.localizedDescription)
                }
                if generation == token {
                    latestDispatch = "Dispatch interrupted or failed · \(selection.route)\n\(summary)"
                }
                throw error
            }
            if let dispatchID {
                taskState?.finishAction(id: dispatchID)
                actionHistory.finish(id: dispatchID)
            }
            if let historyID = currentHistoryEntryID,
               !["wait", "screenshot"].contains(action.type.lowercased()) {
                conversationContext.recordDispatchedAction(id: historyID, description: call.description)
            }
        }
        // This trace comes from dispatched input, not model prose: wait and
        // screenshot batches must not masquerade as actual clicks.
        latestDispatch = "Dispatched · \(selection.route)\n\(summary)"
        return summary
    }

    // MARK: - Accepted task and history

    private func receiveAnswer(_ text: String, to question: String) {
        let answer = QuestionAnswer(question: question, text: text)
        answers.append(answer)
        command = ""
        log(text, detail: "Answer to: \(question)")
        guard !working else { return }
        error = nil
        status = "Answered"
        latestDecision = "Luna → Answer"
        showNotice(answer.preview, duration: 20)
    }

    private func finishIgnoredTurn(newInput: Bool, token: UUID) {
        if newInput {
            pendingInputs.removeAll()
            if taskState != nil {
                // Ignored conversation does not alter the accepted goal.
                if taskPausedForUser { finishTask(token, keepingTask: true) }
                else { launchTask() }
                return
            }
        }
        finishHistory(status: .stopped, outcome: "The model ended the task without confirming completion.")
        finishTask(token)
    }

    private func acceptInput(_ text: String, selection: SelectedAction, turn: ModelTurn) {
        executionRevision += 1
        if taskState != nil {
            let outcome = (selection.nativeRelationship ?? turn.taskUpdate?.kind) == .replace
                ? "Replaced by a later request. Earlier actions may already have taken effect."
                : "Continued with a later instruction; remaining work was revised."
            finishHistory(status: .paused, outcome: outcome)
            if let relationship = selection.nativeRelationship {
                taskState?.applyAcceptedUtterance(text, relationship: relationship)
            } else {
                taskState?.appendUtterance(text)
            }
        } else {
            taskState = TaskSteeringState(command: text)
        }
        if let update = turn.taskUpdate { taskState?.apply(update: update) }
        lastAcceptedGoal = taskState?.goal
        pendingInputs.removeAll()
        taskPausedForUser = false
        taskClarification = nil
        currentHistoryEntryID = conversationContext.begin(command: text, resolvedGoal: taskState?.goal)
        log(text, detail: "Command")
    }

    private func completeCommand(outcome: String, token: UUID) {
        finishHistory(status: .completed, outcome: outcome)
        log(outcome, detail: "Response")
        finishTask(token)
    }

    private func finishHistory(status: CommandContext.Status, outcome: String) {
        guard let id = currentHistoryEntryID else { return }
        conversationContext.finish(id: id, outcome: outcome, status: status)
        currentHistoryEntryID = nil
    }

    // MARK: - Cancellation and completion

    func cancel(silent: Bool = false) {
        // TESTING: record local cancellation before the trace freezes; first reason wins.
        benchmarkRecorder?.noteStop(.manualStop)
        let wasWorking = working
        executionRevision += 1
        submittedBehaviors.removeAll()
        preparedInput = nil
        finishHistory(status: .stopped, outcome: "Stopped before completion. Earlier actions may already have taken effect.")
        invalidateSpeculativeCapture()
        speechScreening.cancel()
        noticeTask?.cancel()
        retireCurrentWork(outcome: .cancelled)
        for timing in voiceTimings.values { timing.finish(.cancelled) }
        voiceTimings.removeAll()
        screeningTiming = nil
        taskState = nil
        pendingInputs.removeAll()
        taskPausedForUser = false
        taskClarification = nil
        working = false
        voice.setExecuting(false)
        transcript = ""
        if !silent {
            status = "Stopped"
            if wasWorking { log("Stopped immediately", detail: "Queued actions cancelled") }
        }
        showRestingState()
    }
    private func checkCurrentTask(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func finishTask(_ token: UUID, keepingTask: Bool = false, outcome: PipelineTiming.Outcome = .succeeded) {
        guard generation == token else { return }
        executionRevision += 1
        runningTiming?.finish(outcome)
        runningTiming = nil
        if !keepingTask {
            taskState = nil
            taskPausedForUser = false
            taskClarification = nil
        }
        pendingInputs.removeAll()
        working = false
        voice.setExecuting(false)
        runningTask = nil
        transcript = ""
        status = active ? "Ready for your next command" : "Waiting for Hey Mouse"
        showRestingState()
    }
    // MARK: - Presentation and usage

    private func retainTiming(_ timing: PipelineTiming) {
        guard !timingTraces.contains(where: { $0.id == timing.id }) else { return }
        timingTraces.insert(timing, at: 0)
        if timingTraces.count > 10 { timingTraces.removeLast(timingTraces.count - 10) }
        // Evict display history only. A replay still owns its candidate mapping
        // until submission/invalidation, even if newer reports push it offscreen.
    }

    private func showRestingState() {
        guard !working else { return }
        notch.show(active && voice.isRunning ? .active : .standby)
    }
    private func showNotice(_ message: String, duration: Double = 5) {
        noticeTask?.cancel()
        notch.show(.notice(message))
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard let self, !self.working else { return }
            self.showRestingState()
        }
    }
    private func recordRequestStarted(timing: PipelineTiming? = nil) throws {
        // TESTING BEGIN: reserve before every endpoint attempt, including fallback.
        if let recorder = benchmarkRecorder, recorder.isRunning, let timing {
            try recorder.reserveRequest(timing: timing)
            benchmarkRequestCount = recorder.session.requestCount
        }
        // TESTING END
        budget.reserve()
        persistUsage(timing: timing)
    }
    private func recordUsage(_ turn: ModelTurn, timing: PipelineTiming? = nil) {
        budget.record(turn)
        persistUsage(timing: timing)
    }
    private func persistUsage(timing: PipelineTiming? = nil) {
        let span = timing?.begin("Persist usage accounting")
        if let warning = usageHistory.save(budget) {
            usageWarning = warning
            timing?.end(span, outcome: .failed)
        } else {
            timing?.end(span)
        }
    }

    private func log(_ title: String, detail: String) {
        activity.insert(Activity(title: title, detail: detail), at: 0)
        if activity.count > 20 { activity.removeLast(activity.count - 20) }
    }
}
