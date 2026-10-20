import AppKit
import SwiftUI
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
    let symbol: String
    let date = Date()
}

@MainActor
final class AppModel: ObservableObject {
    @Published var listening = false
    @Published var working = false
    @Published var active = false
    @Published var voiceAuthorized = false
    @Published var status = "Waiting for Hey Mouse"
    @Published var transcript = ""
    @Published var audioLevel = 0.0
    @Published var command = ""
    @Published var error: String?
    @Published var activity: [Activity] = []
    @Published var hasKey = false
    @Published var hasSavedKey = false
    @Published var screenAllowed = false
    @Published var accessibilityAllowed = false
    @Published var budget = DemoBudget()
    @Published var usageWarning: String?
    @Published var launchAtLogin = false
    @Published var showSettings = false
    @Published var lastDuration: Double?
    @Published private(set) var startingVoice = false
    let computer = NativeComputer()
    let voice = VoiceInput()
    private var runningTask: Task<Void, Never>?
    private var generation = UUID()
    private var conversationContext = CommandContext()
    private var currentHistoryEntryID: UUID?
    private var lastAcceptedGoal: String?
    private var speculativeCapture: PendingCapture?
    private var taskState: TaskSteeringState?
    private var pendingInputs: [String] = []
    private var taskPausedForUser = false
    private var taskClarification: String?
    private var retiredWork: Task<Void, Never>?
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
            self.launchTask(captureID: captureID)
        },
        onIgnored: { [weak self] captureID in
            self?.finishSpeechScreening(captureID: captureID)
        },
        onFailure: { [weak self] error, captureID in
            guard let self else { return }
            self.finishSpeechScreening(captureID: captureID)
            self.error = error.localizedDescription
            self.log(error.localizedDescription, detail: "Speech check failed", symbol: "exclamationmark.circle")
            if !self.working {
                self.status = "Command not accepted · try again"
                self.showNotice("Couldn't check command · try again")
            }
        }
    )

    private struct Observation: Sendable {
        let frame: ScreenshotFrame
        let processID: Int32
        let capturedAt: TimeInterval
    }
    private struct PendingCapture {
        let id: UUID
        let generation: UUID
        let task: Task<Observation, Error>
    }
    private var previousApplication: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private let notch = MouseNotchController()
    private var noticeTask: Task<Void, Never>?
    private var started = false
    private let budgetURL: URL
    private var canPersistUsage = true

    init() {
        let storage = UsageStorage()
        budgetURL = storage.usageURL
        let directory = budgetURL.deletingLastPathComponent()
        do {
            try storage.prepare()
            if FileManager.default.fileExists(atPath: budgetURL.path) {
                do {
                    budget = try JSONDecoder().decode(DemoBudget.self, from: Data(contentsOf: budgetURL))
                } catch {
                    let backup = directory.appendingPathComponent("usage-unreadable-\(UUID().uuidString).json")
                    try FileManager.default.copyItem(at: budgetURL, to: backup)
                    usageWarning = "Previous usage could not be read. It was preserved in a backup; this counter starts at zero."
                }
            }
        } catch {
            canPersistUsage = false
            usageWarning = "Usage history is unavailable. Requests remain enabled; this session counts in memory."
        }
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        previousApplication = NSWorkspace.shared.frontmostApplication
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            Task { @MainActor in self?.previousApplication = app }
        }
        voice.onCommand = { [weak self] text in self?.submit(text) }
        voice.onFinalizationStarted = { [weak self] id in self?.startSpeculativeCapture(id) }
        voice.onFinalizationInvalidated = { [weak self] id in self?.invalidateSpeculativeCapture(id) }
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
        voice.onLevel = { [weak self] level in self?.audioLevel = level }
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
            self.log(message, detail: "Voice stopped", symbol: "mic.slash")
            self.showNotice("Voice paused · check Mouse settings")
        }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
    }

    func refreshPermissions() {
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
            voice.stop(); listening = false; active = false
            status = "Microphone paused"; audioLevel = 0; transcript = ""
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
            defer { startingVoice = false; refreshPermissions() }
            do {
                if !voice.isRunning { try await voice.start() }
                listening = voice.isEnabled; error = nil
                if activate { voice.activate() }
                else { showRestingState() }
            } catch {
                self.error = error.localizedDescription; listening = false
                status = "Voice needs attention"
                showNotice("Voice setup needs attention")
            }
        }
    }

    func listenNow() { startVoice(activate: true) }

    func sleep() { voice.deactivate(); active = false; cancel(silent: true); transcript = ""; showRestingState() }

    func requestScreen() { _ = computer.requestScreenRecordingPermission(); refreshPermissions() }
    func requestAccessibility() { _ = computer.requestAccessibilityPermission(); refreshPermissions() }
    func openPrivacy(_ suffix: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") { NSWorkspace.shared.open(url) }
    }
    func saveKey(_ key: String) {
        do { try KeychainStore.save(key); refreshPermissions(); error = nil } catch { self.error = error.localizedDescription }
    }
    func reconnectKey() {
        do { try KeychainStore.authorizeSavedKey(); refreshPermissions(); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch { self.error = error.localizedDescription }
    }

    /// Called at the speech endpoint: the accurate second recognizer and capture
    /// run independently. A revision invalidates this exact candidate.
    private func startSpeculativeCapture(_ id: UUID) {
        invalidateSpeculativeCapture()
        guard active, !working, screenAllowed, accessibilityAllowed,
              NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let token = generation
        let retirement = retiredWork
        let task = Task {
            await retirement?.value
            try Task.checkCancellation()
            self.computer.resetDisplay()
            return try await self.captureObservation()
        }
        speculativeCapture = PendingCapture(id: id, generation: token, task: task)
    }

    private func invalidateSpeculativeCapture(_ id: UUID? = nil) {
        guard let pending = speculativeCapture, id == nil || pending.id == id else { return }
        pending.task.cancel()
        speculativeCapture = nil
    }

    private func captureObservation() async throws -> Observation {
        // Keep the screenshot and foreground app paired. Capturing this while
        // speech finalizes does not require reading an accessibility tree.
        for _ in 0..<2 {
            try Task.checkCancellation()
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            let capturedAt = ProcessInfo.processInfo.systemUptime
            let frame = try await computer.capture()
            try Task.checkCancellation()
            if (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) == pid {
                return Observation(frame: frame, processID: pid, capturedAt: capturedAt)
            }
        }
        throw MouseError.configuration("The foreground app changed while Mouse was observing it. Repeat the command.")
    }

    private func validateObservation(_ observation: Observation) throws {
        try computer.validateFrame(observation.frame)
        guard (NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) == observation.processID else {
            throw MouseError.configuration("The foreground app changed before Mouse could act. Repeat the command in the intended app.")
        }
    }

    func submit(_ value: String? = nil, captureID: UUID? = nil) {
        let text = (value ?? command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if VoiceControl.match(text) != nil { sleep(); return }
        command = ""
        speechScreening.enqueue(text, captureID: captureID)
        if !working {
            transcript = ""
            noticeTask?.cancel()
            status = "Checking command…"
            notch.show(.thinking)
        }
    }

    private func screenUtterance(_ text: String) async throws -> String? {
        try Task.checkCancellation()
        guard let key = try KeychainStore.load() else {
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
        }
        let context = Context(
            currentGoal: taskState?.goal,
            acceptedPendingCommands: pendingInputs,
            awaitingUserInput: taskPausedForUser,
            clarification: taskPausedForUser ? taskClarification : nil,
            lastAcceptedCommand: conversationContext.entries.last?.command,
            lastAcceptedGoal: lastAcceptedGoal
        )
        let contextData = try JSONEncoder().encode(context)
        let client = SpeechIntentFilter(apiKey: key)
        countRequest()
        let result = try await client.classify(
            utterance: text, taskContext: String(decoding: contextData, as: UTF8.self)
        )
        budget.record(inputTokens: result.inputTokens, outputTokens: result.outputTokens)
        persistUsage()
        try Task.checkCancellation()
        return result.command
    }

    private func finishSpeechScreening(captureID: UUID?) {
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

    /// Wait for cancelled input cleanup before taking a replacement screenshot.
    /// An interrupted drag must release its button before the next task can act.
    private func retireCurrentWork() {
        generation = UUID()
        guard let old = runningTask else { return }
        old.cancel()
        let prior = retiredWork
        retiredWork = Task {
            await prior?.value
            await old.value
        }
        runningTask = nil
    }

    private func launchTask(captureID: UUID? = nil) {
        guard !pendingInputs.isEmpty || taskState != nil else {
            working = false
            voice.setExecuting(false)
            showRestingState()
            return
        }
        // Transfer the capture before retiring the previous generation.
        let prefetched = speculativeCapture.flatMap { $0.id == captureID ? $0 : nil }
        if prefetched != nil { speculativeCapture = nil }
        let previousGeneration = generation
        retireCurrentWork()
        taskState?.markUnfinishedActionsUncertain()
        invalidateSpeculativeCapture()
        noticeTask?.cancel()
        let hasNewInput = !pendingInputs.isEmpty
        let text = hasNewInput ? pendingInputs.joined(separator: "\n")
            : "Continue the already accepted active task from its recorded progress and the current screen."
        let context = taskState?.contextText ?? ""
        let history = conversationContext.text
        let retirement = retiredWork
        command = ""; transcript = ""; error = nil; lastDuration = nil
        let token = UUID(); generation = token
        working = true; status = "Thinking…"; voice.setExecuting(true)
        notch.show(.thinking)
        let started = Date()
        runningTask = Task {
            defer { prefetched?.task.cancel() }
            do {
                await retirement?.value
                try check(token)
                guard screenAllowed else { throw MouseError.permission("Allow Screen Recording in Mouse Settings to see the app you want to control.") }
                guard accessibilityAllowed else { throw MouseError.permission("Allow Accessibility in Mouse Settings to click and type.") }
                guard let key = try KeychainStore.load() else { throw MouseError.configuration("Add your OpenAI API key in Settings.") }
                var restoredFocus = false
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    previousApplication?.activate(options: [])
                    try await Task.sleep(for: .milliseconds(220))
                    restoredFocus = true
                }
                NSApp.windows.filter { $0.isVisible && ($0.canBecomeMain || $0.canBecomeKey) }.forEach { $0.orderOut(nil) }
                var initial: Observation?
                if let prefetched, let captureID, !restoredFocus {
                    let result = await withTaskCancellationHandler { await prefetched.task.result } onCancel: { prefetched.task.cancel() }
                    try check(token)
                    if case let .success(observation) = result {
                        let stamp = CaptureStamp(utteranceID: prefetched.id, generation: prefetched.generation,
                                                 processID: observation.processID, capturedAt: observation.capturedAt)
                        if stamp.canReuse(utteranceID: captureID, generation: previousGeneration,
                                          processID: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0,
                                          now: ProcessInfo.processInfo.systemUptime),
                           (try? validateObservation(observation)) != nil {
                            initial = observation
                        }
                    }
                }
                if initial == nil {
                    computer.resetDisplay()
                    initial = try await captureObservation()
                }
                try check(token)
                guard let observation = initial else { throw MouseError.configuration("No screen observation is available.") }
                try await runCommand(text, hasNewInput: hasNewInput, history: history, taskContext: context,
                                     key: key, observation: observation, token: token, started: started)
            } catch is CancellationError {
                // A replacement owns its own history and UI; retired tasks cannot
                // finish or overwrite the new command's entry.
                guard generation == token else { return }
                finishHistory(status: .stopped, outcome: "Stopped before completion. Earlier actions may already have taken effect.")
                finish(token)
            } catch {
                guard generation == token else { return }
                finishHistory(status: .failed, outcome: error.localizedDescription + " Completion was not confirmed; earlier actions may already have taken effect.")
                self.error = error.localizedDescription
                status = "Paused"
                log(error.localizedDescription, detail: "Needs attention", symbol: "exclamationmark.circle")
                finish(token)
                showNotice("Paused · check Mouse settings")
            }
        }
    }

    private func runCommand(_ text: String, hasNewInput: Bool, history: String, taskContext: String,
                            key: String, observation initial: Observation, token: UUID, started: Date) async throws {
        let client = OpenAIComputerClient(apiKey: key)
        var observation = initial
        var step = 0
        var firstTurn = true
        try check(token)
        status = "Choosing the next action…"
        countRequest()
        var turn = try await client.begin(command: text, frame: observation.frame, context: history, activeTask: taskContext)
        while true {
            try check(token)
            record(turn)
            // Raw speech and an in-flight text check do not invalidate this
            // response. A confirmed redirect or immediate Stop changes its token.
            try check(token)
            if turn.ignored {
                if firstTurn && hasNewInput {
                    pendingInputs.removeAll()
                    if taskState != nil {
                        // Ignored conversation does not alter the accepted goal.
                        if taskPausedForUser { finish(token, keepingTask: true) }
                        else { launchTask() }
                        return
                    }
                }
                finishHistory(status: .stopped, outcome: "Luna ended the task without confirming completion.")
                finish(token)
                return
            }
            if firstTurn && hasNewInput {
                if taskState != nil {
                    let outcome = turn.taskUpdate?.kind == .replace
                        ? "Replaced by a later request. Earlier actions may already have taken effect."
                        : "Continued with a later instruction; remaining work was revised."
                    finishHistory(status: .paused, outcome: outcome)
                    taskState?.appendUtterance(text)
                } else {
                    taskState = TaskSteeringState(command: text)
                }
                if let update = turn.taskUpdate { taskState?.apply(update: update) }
                lastAcceptedGoal = taskState?.goal
                pendingInputs.removeAll()
                taskPausedForUser = false
                taskClarification = nil
                currentHistoryEntryID = conversationContext.begin(command: text)
                log(text, detail: "Command", symbol: "waveform")
            }
            firstTurn = false
            if let reason = turn.pauseReason {
                error = reason; status = "Needs your input"
                finishHistory(status: .paused, outcome: reason)
                taskPausedForUser = true
                taskClarification = reason
                log(reason, detail: "Needs your input", symbol: "questionmark.circle")
                finish(token, keepingTask: true); showNotice(reason, duration: 12)
                return
            }
            if turn.calls.isEmpty {
                completeCommand(outcome: turn.message.isEmpty ? "Done" : turn.message, token: token, started: started)
                return
            }
            let actions = turn.calls.flatMap(\.actions)
            guard !actions.isEmpty, actions.count <= 12 else { throw MouseError.invalidAction("The model returned an empty or oversized action batch.") }
            guard turn.calls.allSatisfy({ $0.safetyChecks.isEmpty }) else {
                throw MouseError.permission("Mouse paused for the requested review. Give a new instruction when ready.")
            }
            try validateObservation(observation)
            for action in actions { try computer.validateAction(action, frame: observation.frame) }
            var outputs: [(callID: String, frame: ScreenshotFrame)] = []
            for call in turn.calls {
                try check(token)
                status = call.description; notch.show(.working(call.description))
                for action in call.actions {
                    try check(token)
                    let dispatchID = taskState?.beginAction(action: action, description: call.description)
                    try await computer.execute(action, frame: observation.frame)
                    try check(token)
                    if let dispatchID { taskState?.finishAction(id: dispatchID) }
                }
                // Let the interface settle before capturing what Luna will see next.
                // This suspension is cancellable: Stop interrupts it immediately.
                try await Task.sleep(for: .milliseconds(1_000))
                try check(token)
                observation = try await captureObservation()
                outputs.append((callID: call.callID, frame: observation.frame))
            }
            log(turn.calls.map(\.description).joined(separator: " · "), detail: "Step \(step + 1)", symbol: "cursorarrow.click")
            step += 1
            try check(token)
            countRequest(); status = "Checking the result"
            notch.show(.thinking)
            // The same Responses chain carries the task and prior actions forward.
            turn = try await client.continueTurn(responseID: turn.id, outputs: outputs)
        }
    }

    private func completeCommand(outcome: String, token: UUID, started: Date) {
        finishHistory(status: .completed, outcome: outcome)
        log(outcome, detail: "Response", symbol: "text.bubble")
        lastDuration = Date().timeIntervalSince(started)
        finish(token)
    }

    private func finishHistory(status: CommandContext.Status, outcome: String) {
        guard let id = currentHistoryEntryID else { return }
        conversationContext.finish(id: id, outcome: outcome, status: status)
        currentHistoryEntryID = nil
    }

    func cancel(silent: Bool = false) {
        let wasWorking = working
        finishHistory(status: .stopped, outcome: "Stopped before completion. Earlier actions may already have taken effect.")
        invalidateSpeculativeCapture()
        speechScreening.cancel()
        noticeTask?.cancel()
        retireCurrentWork()
        taskState = nil; pendingInputs.removeAll(); taskPausedForUser = false; taskClarification = nil
        working = false; voice.setExecuting(false)
        transcript = ""
        if !silent { status = "Stopped"; if wasWorking { log("Stopped immediately", detail: "Queued actions cancelled", symbol: "stop.circle") } }
        showRestingState()
    }
    private func check(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
    }
    private func finish(_ token: UUID, keepingTask: Bool = false) {
        guard generation == token else { return }
        if !keepingTask { taskState = nil; taskPausedForUser = false; taskClarification = nil }
        pendingInputs.removeAll()
        working = false; voice.setExecuting(false); runningTask = nil; transcript = ""
        status = active ? "Ready for your next command" : "Waiting for Hey Mouse"
        showRestingState()
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
    private func countRequest() {
        budget.reserve()
        persistUsage()
    }
    private func record(_ turn: ModelTurn) {
        budget.record(turn)
        persistUsage()
    }
    private func persistUsage() {
        guard canPersistUsage else { return }
        do { try JSONEncoder().encode(budget).write(to: budgetURL, options: .atomic) }
        catch {
            canPersistUsage = false
            usageWarning = "Usage could not be saved. Requests remain enabled; this session counts in memory."
        }
    }
    private func log(_ title: String, detail: String, symbol: String) {
        activity.insert(Activity(title: title, detail: detail, symbol: symbol), at: 0)
        if activity.count > 20 { activity.removeLast(activity.count - 20) }
    }
}
