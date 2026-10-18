import AppKit
import SwiftUI
import Combine
import ServiceManagement
#if SWIFT_PACKAGE
import ChosenCore
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
    @Published var status = "Ready when you are"
    @Published var transcript = ""
    @Published var audioLevel = 0.0
    @Published var command = ""
    @Published var error: String?
    @Published var activity: [Activity] = []
    @Published var hasKey = false
    @Published var screenAllowed = false
    @Published var accessibilityAllowed = false
    @Published var budget = DemoBudget()
    @Published var usageWarning: String?
    @Published var launchAtLogin = false
    @Published var showSettings = false
    @Published var lastDuration: Double?
    let computer = NativeComputer()
    let voice = VoiceInput()
    private var runningTask: Task<Void, Never>?
    private var generation = UUID()
    private var conversationContext = ""
    private var previousApplication: NSRunningApplication?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionTimer: Timer?
    private var hiddenWindows: [NSWindow] = []
    private let budgetURL: URL
    private var canPersistUsage = true

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chosen", isDirectory: true)
        budgetURL = directory.appendingPathComponent("usage.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        voice.onPartial = { [weak self] text in self?.transcript = text }
        voice.onLevel = { [weak self] level in self?.audioLevel = level }
        voice.onStatus = { [weak self] state in guard self?.working == false else { return }; self?.status = state }
        voice.onStop = { [weak self] in self?.cancel() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in Task { @MainActor in self?.refreshPermissions() } }
    }

    func refreshPermissions() {
        hasKey = KeychainStore.exists()
        screenAllowed = computer.screenRecordingGranted
        accessibilityAllowed = computer.accessibilityGranted
        listening = voice.isRunning
    }

    func toggleListening() {
        if listening { voice.stop(); listening = false; status = "Microphone off"; audioLevel = 0; return }
        Task {
            do { try await voice.start(); listening = voice.isRunning; error = nil }
            catch { self.error = error.localizedDescription; listening = false; status = "Voice needs attention" }
        }
    }

    func listenNow() {
        Task {
            do {
                if !voice.isRunning { try await voice.start() }
                listening = voice.isRunning
                voice.activate()
            } catch { self.error = error.localizedDescription }
        }
    }

    func requestScreen() { _ = computer.requestScreenRecordingPermission(); refreshPermissions() }
    func requestAccessibility() { _ = computer.requestAccessibilityPermission(); refreshPermissions() }
    func openPrivacy(_ suffix: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(suffix)") { NSWorkspace.shared.open(url) }
    }
    func saveKey(_ key: String) {
        do { try KeychainStore.save(key); hasKey = true; error = nil } catch { self.error = error.localizedDescription }
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
        if ["stop", "cancel", "stop chosen", "cancel that"].contains(text.lowercased()) { cancel(); return }
        cancel(silent: true)
        command = ""; transcript = text; error = nil; lastDuration = nil
        let token = UUID(); generation = token
        working = true; status = "Looking at your screen"; voice.setExecuting(true)
        let started = Date()
        log(text, detail: "Command", symbol: "waveform")
        runningTask = Task {
            do {
                guard screenAllowed else { throw ChosenError.permission("Allow Screen Recording so Chosen can see the app you want to control.") }
                guard accessibilityAllowed else { throw ChosenError.permission("Allow Accessibility so Chosen can click and type.") }
                guard let key = try KeychainStore.load() else { throw ChosenError.configuration("Add your OpenAI API key in Settings.") }
                let client = OpenAIComputerClient(apiKey: key)
                // Typed commands temporarily move focus into Chosen. Restore the target app before capturing.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
                    previousApplication?.activate(options: [])
                    try await Task.sleep(for: .milliseconds(220))
                }
                hiddenWindows = NSApp.windows.filter { $0.isVisible && ($0.canBecomeMain || $0.canBecomeKey) }
                hiddenWindows.forEach { $0.orderOut(nil) }
                computer.resetDisplay()
                var frame = try await computer.capture()
                try check(token)
                countRequest()
                status = "Understanding your command"
                var turn = try await client.begin(command: text, frame: frame, context: conversationContext)
                for step in 0..<DemoBudget.stepsPerCommand {
                    try check(token)
                    record(turn)
                    if turn.calls.isEmpty {
                        let result = turn.message.isEmpty ? "Done" : turn.message
                        status = "Ready for your next command"
                        log(result, detail: "Response", symbol: "text.bubble")
                        conversationContext = String("Previous user command: \(text)\nResult: \(result)".suffix(2000))
                        lastDuration = Date().timeIntervalSince(started)
                        finish(token)
                        return
                    }
                    guard step + 1 < DemoBudget.stepsPerCommand else { throw ChosenError.limit("Paused at the demo’s step limit. Give the next instruction to continue.") }
                    let allActions = turn.calls.flatMap(\.actions)
                    guard !allActions.isEmpty, allActions.count <= 12 else { throw ChosenError.invalidAction("The model returned an empty or oversized action batch.") }
                    guard turn.calls.allSatisfy({ $0.safetyChecks.isEmpty }) else {
                        throw ChosenError.permission("The model requested a safety check. Chosen paused before acting. Review the screen and give a new, explicit instruction.")
                    }
                    for action in allActions { try computer.validateAction(action, frame: frame) }
                    var outputs: [(callID: String, frame: ScreenshotFrame)] = []
                    for call in turn.calls {
                        for action in call.actions {
                            try check(token)
                            status = actionTitle(action)
                            try await computer.execute(action, frame: frame)
                        }
                        try await Task.sleep(for: .milliseconds(350))
                        try check(token)
                        frame = try await computer.capture()
                        outputs.append((callID: call.callID, frame: frame))
                    }
                    log("Step \(step + 1)", detail: allActions.map { $0.type.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · "), symbol: "cursorarrow.click")
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
            }
            finish(token)
        }
    }

    func cancel(silent: Bool = false) {
        let wasWorking = working
        generation = UUID(); runningTask?.cancel(); runningTask = nil
        working = false; voice.setExecuting(false)
        restoreWindows()
        if !silent { status = "Stopped"; if wasWorking { log("Stopped immediately", detail: "Queued actions cancelled", symbol: "stop.circle") } }
    }
    private func check(_ token: UUID) throws { try Task.checkCancellation(); guard generation == token else { throw CancellationError() } }
    private func finish(_ token: UUID) { guard generation == token else { return }; working = false; voice.setExecuting(false); runningTask = nil; restoreWindows() }
    private func restoreWindows() { hiddenWindows.forEach { $0.orderFront(nil) }; hiddenWindows.removeAll() }
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
    private func actionTitle(_ action: ComputerAction) -> String {
        switch action.type {
        case "click", "double_click": return "Clicking"
        case "type": return "Typing"
        case "keypress": return "Pressing \(action.keys?.joined(separator: " + ") ?? "a key")"
        case "scroll": return "Scrolling"
        case "drag": return "Dragging"
        case "wait": return "Waiting for the app"
        default: return "Checking your screen"
        }
    }
}
