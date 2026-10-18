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
    private var conversationContext = ""
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
        voice.onPartial = { [weak self] text in
            guard let self, !self.working, self.transcript != text else { return }
            self.transcript = text
            self.noticeTask?.cancel()
            if self.active { self.notch.show(text.isEmpty ? .active : .transcribing(text)) }
        }
        voice.onLevel = { [weak self] level in self?.audioLevel = level }
        voice.onStatus = { [weak self] state in guard self?.working == false else { return }; self?.status = state }
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
        listening = voice.isRunning
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
                listening = voice.isRunning; error = nil
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

    func submit(_ value: String? = nil) {
        let text = (value ?? command).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let control = VoiceControl.match(text) {
            switch control {
            case .sleep: sleep()
            }
            return
        }
        // Luna decides intent from the complete utterance and screen context.
        // There is no local vocabulary or command-pattern admission check.
        cancel(silent: true)
        command = ""; transcript = text; error = nil; lastDuration = nil
        let token = UUID(); generation = token
        working = true; status = "Looking at your screen"; voice.setExecuting(true)
        notch.show(.transcribing(text))
        let started = Date()
        runningTask = Task {
            do {
                guard screenAllowed else { throw MouseError.permission("Allow Screen Recording in Mouse Settings to see the app you want to control.") }
                guard accessibilityAllowed else { throw MouseError.permission("Allow Accessibility in Mouse Settings to click and type.") }
                guard let key = try KeychainStore.load() else { throw MouseError.configuration("Add your OpenAI API key in Settings.") }
                let client = OpenAIComputerClient(apiKey: key)
                // Typed commands temporarily move focus into Settings. Restore the target app before capturing.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    previousApplication?.activate(options: [])
                    try await Task.sleep(for: .milliseconds(220))
                }
                // The click-through notch cannot become key/main and stays visible.
                NSApp.windows.filter { $0.isVisible && ($0.canBecomeMain || $0.canBecomeKey) }.forEach { $0.orderOut(nil) }
                computer.resetDisplay()
                var frame = try await computer.capture()
                try check(token)
                countRequest()
                status = "Understanding your command"
                var turn = try await client.begin(command: text, frame: frame, context: conversationContext)
                for step in 0..<DemoBudget.stepsPerCommand {
                    try check(token)
                    record(turn)
                    if turn.ignored {
                        // Ignored speech produces no answer, action, or notice.
                        status = active ? "Ready for your next command" : "Waiting for Hey Mouse"
                        finish(token)
                        return
                    }
                    if step == 0 { log(text, detail: "Command", symbol: "waveform") }
                    if let reason = turn.pauseReason {
                        error = reason
                        status = "Needs your input"
                        conversationContext = String("Previous user command: \(text)\nPaused: \(reason)".suffix(2000))
                        log(reason, detail: "Needs your input", symbol: "questionmark.circle")
                        finish(token)
                        showNotice(reason, duration: 12)
                        return
                    }
                    if turn.calls.isEmpty {
                        let result = turn.message.isEmpty ? "Done" : turn.message
                        status = active ? "Ready for your next command" : "Waiting for Hey Mouse"
                        log(result, detail: "Response", symbol: "text.bubble")
                        conversationContext = String("Previous user command: \(text)\nResult: \(result)".suffix(2000))
                        lastDuration = Date().timeIntervalSince(started)
                        finish(token)
                        return
                    }
                    guard step + 1 < DemoBudget.stepsPerCommand else { throw MouseError.limit("Paused at the demo’s step limit. Give the next instruction to continue.") }
                    let allActions = turn.calls.flatMap(\.actions)
                    guard !allActions.isEmpty, allActions.count <= 12 else { throw MouseError.invalidAction("The model returned an empty or oversized action batch.") }
                    guard turn.calls.allSatisfy({ $0.safetyChecks.isEmpty }) else {
                        throw MouseError.permission("The model requested a safety check. Mouse paused before acting. Review the screen and give a new, explicit instruction.")
                    }
                    for action in allActions { try computer.validateAction(action, frame: frame) }
                    var outputs: [(callID: String, frame: ScreenshotFrame)] = []
                    for call in turn.calls {
                        try check(token)
                        status = call.description
                        notch.show(.working(call.description))
                        for action in call.actions {
                            try check(token)
                            try await computer.execute(action, frame: frame)
                        }
                        try await Task.sleep(for: .milliseconds(350))
                        try check(token)
                        frame = try await computer.capture()
                        outputs.append((callID: call.callID, frame: frame))
                    }
                    log(turn.calls.map(\.description).joined(separator: " · "), detail: "Step \(step + 1)", symbol: "cursorarrow.click")
                    countRequest()
                    status = "Checking the result"
                    turn = try await client.continueTurn(responseID: turn.id, outputs: outputs)
                }
            } catch is CancellationError {
                // The replacement command owns status; late responses cannot execute.
            } catch {
                guard generation == token else { return }
                self.error = error.localizedDescription
                status = "Paused"
                log(error.localizedDescription, detail: "Needs attention", symbol: "exclamationmark.circle")
                finish(token)
                showNotice("Paused · check Mouse settings")
                return
            }
            finish(token)
        }
    }

    func cancel(silent: Bool = false) {
        let wasWorking = working
        noticeTask?.cancel()
        generation = UUID(); runningTask?.cancel(); runningTask = nil
        working = false; voice.setExecuting(false)
        transcript = ""
        if !silent { status = "Stopped"; if wasWorking { log("Stopped immediately", detail: "Queued actions cancelled", symbol: "stop.circle") } }
        showRestingState()
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard generation == token else { throw CancellationError() } }
    private func finish(_ token: UUID) {
        guard generation == token else { return }
        working = false; voice.setExecuting(false); runningTask = nil; transcript = ""
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
