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
    @Published private(set) var timingTraces: [PipelineTiming] = []
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
    // Execution and speech screening have separate lifetimes. Background speech
    // must finish its text-only check before it can retire an accepted task.
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
    private lazy var speechScreening = SpeechScreeningQueue(
        check: { [weak self] text in
            guard let self else { throw CancellationError() }
            return try await self.screenUtterance(text)
        },
        onAccepted: { [weak self] command, captureID in
            guard let self else { return }
            // Only model-accepted speech may retire work. Keep accepted fragments
            // until the execution model incorporates them into its complete goal.
            self.pendingInputs.append(command)
            let timing = self.screeningTiming
            self.screeningTiming = nil
            if let captureID { self.voiceTimings.removeValue(forKey: captureID) }
            timing?.mark("Speech command accepted")
            self.launchTask(captureID: captureID, timing: timing)
        },
        onIgnored: { [weak self] captureID in
            self?.finishSpeechScreening(captureID: captureID)
        },
        onFailure: { [weak self] error, captureID in
            guard let self else { return }
            self.finishSpeechScreening(captureID: captureID)
            self.error = error.localizedDescription
            self.log(error.localizedDescription, detail: "Speech check failed")
            if !self.working {
                self.status = "Command not accepted · try again"
                self.showNotice("Couldn't check command · try again")
            }
        },
        onCheckStarted: { [weak self] _, timing in self?.screeningTiming = timing }
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

    // MARK: - Initialization and voice events

    init() {
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
        guard active, !working, screenAllowed, accessibilityAllowed,
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
        command = ""
        // The queue takes ownership now; replay associations are independent of
        // the ten-report UI limit and are needed only until this handoff.
        let timing = captureID.flatMap { voiceTimings.removeValue(forKey: $0) } ?? PipelineTiming(origin: .typed)
        retainTiming(timing)
        timing.mark("Command submitted for screening")
        speechScreening.enqueue(text, captureID: captureID, timing: timing)
        if !working {
            transcript = ""
            noticeTask?.cancel()
            status = "Checking command…"
            notch.show(.thinking)
        }
    }

    private func screenUtterance(_ text: String) async throws -> String? {
        let timing = screeningTiming
        try Task.checkCancellation()
        guard let key = try measureStage(timing, "Speech screening: load API key", operation: { try KeychainStore.load() }) else {
            throw MouseError.configuration("Add your OpenAI API key in Settings.")
        }
        // No screenshots, action records, or response-chain ID go to this call.
        // Read the context when a queued utterance starts, so prior accepted
        // fragments are available without treating background chat as context.
        struct Context: Encodable {
            let currentGoal: String?
            let acceptedPendingCommands: [String]
            let awaitingUserInput: Bool
            let clarification: String?
            let lastAcceptedCommand: String?
            let lastAcceptedGoal: String?
            let recentAcceptedCommands: [CommandContext.Entry]
        }
        let contextData = try measureStage(timing, "Speech screening context encoding") {
            let context = Context(
                currentGoal: taskState?.goal,
                acceptedPendingCommands: pendingInputs,
                awaitingUserInput: taskPausedForUser,
                clarification: taskPausedForUser ? taskClarification : nil,
                lastAcceptedCommand: conversationContext.entries.last?.command,
                lastAcceptedGoal: lastAcceptedGoal,
                // Intent screening needs the recent referents, not a second copy of
                // the entire session on every background utterance. Each retained
                // command is complete; action models still receive the full history.
                recentAcceptedCommands: Array(conversationContext.entries.suffix(3))
            )
            return try JSONEncoder().encode(context)
        }
        let client = SpeechIntentFilter(apiKey: key)
        recordRequestStarted(timing: timing)
        let result = try await client.classify(
            utterance: text, taskContext: String(decoding: contextData, as: UTF8.self), timing: timing
        )
        budget.record(inputTokens: result.inputTokens, outputTokens: result.outputTokens)
        persistUsage(timing: timing)
        try Task.checkCancellation()
        return result.command
    }

    private func finishSpeechScreening(captureID: UUID?) {
        screeningTiming = nil
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

    private func launchTask(captureID: UUID? = nil, timing suppliedTiming: PipelineTiming? = nil) {
        guard !pendingInputs.isEmpty || taskState != nil else {
            working = false
            voice.setExecuting(false)
            showRestingState()
            return
        }
        let timing = suppliedTiming ?? PipelineTiming(origin: .continued)
        retainTiming(timing)
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
                let observation = try await measureStage(timing, "Initial observation") {
                    try await initialObservation(
                        prefetched: prefetched, captureID: captureID,
                        previousGeneration: previousGeneration, token: token, timing: timing)
                }
                try await runCommand(text, hasNewInput: hasNewInput, history: history,
                                     key: key, observation: observation, token: token, timing: timing)
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

    private func runCommand(_ text: String, hasNewInput: Bool, history: SelectionHistory,
                            key: String, observation initial: ScreenObservation, token: UUID, timing: PipelineTiming) async throws {
        let selector = DecisionsClient(apiKey: key)
        let generator = OpenAIComputerClient(apiKey: key)
        var observation = initial
        var step = 0
        var firstTurn = true
        var progressGuard = ActionProgressGuard()
        while true {
            try checkCurrentTask(token)
            status = "Choosing the next action…"
            notch.show(.thinking)
            let newInput = firstTurn && hasNewInput
            let input = newInput ? text : (taskState?.goal ?? text)
            let (selection, turn) = try await measureStage(timing, "Step \(step + 1): choose action") {
                try await chooseNextAction(
                    input: input, newInput: newInput, history: history, observation: observation,
                    selector: selector, generator: generator, token: token, timing: timing)
            }
            let native = selection.nativeTarget
            // Raw speech and an in-flight text check do not invalidate this
            // response. A confirmed redirect or immediate Stop changes its token.
            try checkCurrentTask(token)
            if turn.ignored {
                timing.finish(.ignored)
                finishIgnoredTurn(newInput: newInput, token: token)
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
            try measureStage(timing, "Step \(step + 1): validate observation and actions") {
                try screenObserver.validate(observation)
                if native == nil {
                    for action in actions { try computer.validateAction(action, frame: observation.frame) }
                }
            }
            for call in turn.calls {
                let before = observation
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
                log(call.description,
                    detail: "Step \(step + 1) · \(selection.route) · \(selection.choiceSummary)\n\(dispatchSummary)")
                // Stop an exact unchanged-state replay, not a long task. This
                // does not infer success from an AX return code or retry input.
                let stalled: String?
                let progress = timing.begin("Step \(step + 1): progress check")
                if let native {
                    stalled = progressGuard.recordNative(action: native.action, element: native.element,
                                                         before: before.frame, after: observation.frame,
                                                         processIDBefore: before.processID, processIDAfter: observation.processID)
                } else {
                    stalled = progressGuard.recordGenerated(call.actions,
                                                            before: before.frame, after: observation.frame,
                                                            processIDBefore: before.processID, processIDAfter: observation.processID)
                }
                timing.end(progress)
                if let stalled {
                    error = stalled
                    status = "No visible progress"
                    latestDispatch += "\nPaused: repeatedly observed an unchanged screen."
                    finishHistory(status: .paused, outcome: stalled)
                    taskPausedForUser = true
                    taskClarification = stalled
                    log(stalled, detail: "Repeated action paused")
                    finishTask(token, keepingTask: true, outcome: .paused)
                    showNotice("No visible progress · paused", duration: 12)
                    return
                }
            }
            step += 1
            try checkCurrentTask(token)
            // Every next step returns to Decisions. Generated actions are a single
            // fallback operation, never an unobserved plan for the rest of a task.
        }
    }

    /// Selection and optional generation form one turn; both remain cancellable
    /// before any accepted-goal or dispatch state is changed.
    private func chooseNextAction(input: String, newInput: Bool, history: SelectionHistory,
                                  observation: ScreenObservation, selector: DecisionsClient,
                                  generator: OpenAIComputerClient, token: UUID, timing: PipelineTiming) async throws -> (SelectedAction, ModelTurn) {
        // Classify a new amendment beside the action in the same request.
        // Known native targets remain usable; only an unresolved relationship
        // needs the generator to rewrite the combined intent before acting.
        let (options, contextText) = try measureStage(timing, "Prepare action choices and decision context") {
            let classifiesAmendment = newInput && taskState != nil
            let context = ComputerDecisionContext(
                request: input, isContinuation: !newInput, task: taskState,
                recentCommands: history.commands,
                pendingClarification: taskPausedForUser ? taskClarification : nil,
                snapshot: observation.accessibility
            )
            let options = ComputerDecisionOptions(snapshot: observation.accessibility,
                                              allowNativeActions: true,
                                              allowCompletion: context.hasUIEvidence,
                                              allowIgnore: newInput,
                                              classifyTaskRelationship: classifiesAmendment)
            let contextText = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
            return (options, contextText)
        }
        recordRequestStarted(timing: timing)
        let decision = try await measureStage(timing, "Decisions selection") {
            try await selector.decide(instructions: ComputerDecisionOptions.instructions,
                                     context: contextText,
                                     questions: options.questions, timing: timing)
        }
        try checkCurrentTask(token)
        budget.record(inputTokens: decision.inputTokens, outputTokens: decision.outputTokens, rate: .decisions)
        persistUsage(timing: timing)

        let selection = try measureStage(timing, "Interpret Decisions selection") {
            try SelectedAction(result: decision, options: options, tree: observation.accessibility)
        }
        // Publish selection before generation: even a failed fallback must
        // remain distinguishable from an input that was actually dispatched.
        latestDecision = selection.decisionSummary
        timing.mark("Selected route: \(selection.route)")
        let turn: ModelTurn
        if let immediate = selection.immediateTurn {
            turn = immediate
        } else {
            recordRequestStarted(timing: timing)
            turn = try await measureStage(timing, "Responses action generation") {
                try await generator.begin(command: input, frame: observation.frame, context: history.full,
                                             activeTask: taskState?.contextText ?? "",
                                             pendingClarification: taskPausedForUser ? taskClarification : nil,
                                             accessibility: observation.accessibility.contextText,
                                             continuingTask: !newInput, reviewRequired: selection.operation == .review,
                                             timing: timing)
            }
            try checkCurrentTask(token)
            recordUsage(turn, timing: timing)
        }
        return (selection, turn)
    }

    private func dispatch(_ call: ComputerCall, selection: SelectedAction,
                          observation: ScreenObservation, token: UUID, timing: PipelineTiming) async throws -> String {
        try checkCurrentTask(token)
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
            let dispatchID = taskState?.beginAction(action: action, description: call.description)
            do {
                if let native {
                    // AX revalidates the exact retained element before acting.
                    // An ambiguous result stops here: do not blindly replay it
                    // as a click, since the first action may have taken effect.
                    try await accessibility.perform(action: native.action, targetID: native.element.id,
                                                    snapshotID: observation.accessibility.id,
                                                    processID: observation.processID, timing: timing)
                } else {
                    try await computer.execute(action, frame: observation.frame, timing: timing)
                }
            } catch {
                if generation == token {
                    latestDispatch = "Dispatch interrupted or failed · \(selection.route)\n\(summary)"
                }
                throw error
            }
            try checkCurrentTask(token)
            if let dispatchID { taskState?.finishAction(id: dispatchID) }
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
        let wasWorking = working
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
    private func recordRequestStarted(timing: PipelineTiming? = nil) {
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
