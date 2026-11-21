import SwiftUI

/// Settings, action history, and answers share the expanded menu’s panel and keyboard focus.
struct AtmosMenuSettingsView: View {
    private enum Tab: String, CaseIterable {
        case settings = "Settings"
        case actions = "Actions"
        case answers = "Answers"
    }

    @ObservedObject var model: AppModel
    let perform: (@escaping () -> Void) -> Void
    var isFullScreen = false
    let openCalibration: () -> Void
    @State private var selectedTab = Tab.settings
    @State private var visibleSections: [Int] = []
    @State private var keyInput = ""
    @State private var editingKey = false
    @State private var krispKeyInput = ""
    @State private var editingKrispKey = false

    var body: some View {
        VStack(spacing: 16) {
            Picker("Settings section", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            // The nonactivating panel can inherit a light macOS appearance.
            .environment(\.colorScheme, .dark)
            .labelsHidden()
            .frame(maxWidth: 340)
            .atmosMenuElement(0)

            AtmosMenuPageTransition(page: selectedTab) { tab in
                switch tab {
                case .settings:
                    settingsContent
                case .actions:
                    ActionHistoryView(model: model)
                case .answers:
                    QuestionAnswersView(model: model) {
                        let question = model.command.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !question.isEmpty { model.submitMenuInput(question, fullScreen: isFullScreen, afterClosing: perform) }
                    }
                }
            }
        }
        .frame(maxWidth: 700)
    }

    private func submit() {
        let command = model.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }
        let fullScreen = isFullScreen
        perform { model.submit(command, fromFullScreenMenu: fullScreen) }
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                settingsRow(0) {
                    DisplayTapSettingsView(model: model, monitor: model.displayTaps, openCalibration: openCalibration)
                }
                settingsRow(1) { voiceSection }
                settingsRow(2) { vivaProSection }
                settingsRow(3) { BehaviorSettingsView(model: model) }
                settingsRow(4) { permissionsSection }
                settingsRow(5) { connectionSection }
                settingsRow(6) {
                    Toggle("Open Atmos at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                        .toggleStyle(.switch)
                }
                if let error = model.error {
                    settingsRow(7) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Needs attention", systemImage: "exclamationmark.circle").font(.subheadline.weight(.medium))
                            Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                            Button("Dismiss") { model.error = nil }.controlSize(.small)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                settingsRow(8) { usageSection }
                // TESTING: Remove this hook with BenchmarkSettingsView.
                settingsRow(9) { BenchmarkSettingsView(model: model) }
                settingsRow(10) { ActivityDiagnosticsView(model: model, submit: submit) }
            }
            .scrollTargetLayout()
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
        .onScrollTargetVisibilityChange(idType: Int.self, threshold: 0.01) { ids in
            visibleSections = ids.sorted()
        }
        .onDisappear { visibleSections = [] }
    }

    /// Keep the picker first, then stagger the sections currently in the viewport.
    /// Scrolling to the bottom leaves the page transition duration unchanged.
    private func settingsRow<Content: View>(_ order: Int, @ViewBuilder content: () -> Content) -> some View {
        let visibleOrder = visibleSections.firstIndex(of: order) ?? order
        return content().atmosMenuElement(min(4, visibleOrder + 1)).id(order)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(voiceTitle).font(.headline)
                Spacer()
                Button(model.voiceMonitoringRequested ? "Pause wake listening" : "Enable wake listening") { model.toggleListening() }
                    .buttonStyle(.glass).controlSize(.small)
                    // TESTING: Benchmark trials own microphone pause/restoration.
                    .disabled(model.startingVoice || model.benchmarkEnabled || model.benchmarkTrialInProgress)
            }
        }
    }

    private var voiceTitle: String {
        if model.startingVoice { return "Preparing voice…" }
        if model.microphoneMuted { return "Microphone muted" }
        return model.voiceMonitoringRequested ? "Wake listening enabled" : "Wake listening paused"
    }

    private var vivaProSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("VIVA Pro voice isolation", isOn: $model.preferences.vivaProEnabled)
                .font(.headline).toggleStyle(.switch)
                .disabled(!model.hasKrispKey && !model.preferences.vivaProEnabled)
            Text("Wake detection stays on this Mac. With isolation on, Krisp receives your command after wake, including its buffered start, or live audio when you start menu dictation. Say “stop” to end a voice command. Click the dictation mic again to finish dictating. Muting the microphone stops audio capture.")
                .font(.caption).foregroundStyle(.secondary)
            if editingKrispKey || !model.hasSavedKrispKey {
                SecureField("Krisp developer API key", text: $krispKeyInput)
                    .textFieldStyle(.roundedBorder)
                Button("Save key and enable VIVA Pro") {
                    if model.saveKrispKey(krispKeyInput) {
                        krispKeyInput = ""
                        editingKrispKey = false
                    }
                }.disabled(krispKeyInput.isEmpty).controlSize(.small)
            } else {
                HStack {
                    if !model.hasKrispKey {
                        Button("Reconnect Krisp key") { model.reconnectKrispKey() }
                    }
                    Button("Change Krisp key…") { editingKrispKey = true }
                }.controlSize(.small)
            }
        }
        .padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac permissions").font(.headline)
            permission("Screen Recording", detail: "See the screen during a command", symbol: "macwindow", allowed: model.screenAllowed) { model.requestScreen() }
            Divider()
            permission("Accessibility", detail: "Click, type, and use shortcuts", symbol: "cursorarrow", allowed: model.accessibilityAllowed) { model.requestAccessibility() }
            Divider()
            permission("Microphone", detail: "Listen for the wake phrase and spoken commands", symbol: "mic", allowed: model.voiceAuthorized) { model.requestMicrophonePermission() }
        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }

    private func permission(_ name: String, detail: String, symbol: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if allowed { Image(systemName: "checkmark").font(.callout).foregroundStyle(.secondary).accessibilityLabel("Allowed") }
            else { Button("Allow", action: action).buttonStyle(.glass).controlSize(.small) }
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("OpenAI connection").font(.headline)
                Spacer()
                Text(model.hasKey ? "Connected" : model.hasSavedKey ? "Needs authorization" : "Not connected").font(.callout).foregroundStyle(.secondary)
            }
            if model.hasSavedKey && !model.hasKey && !editingKey {
                Text("macOS needs to authorize this updated build to use your saved key.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Reconnect saved key") { model.reconnectKey() }.buttonStyle(.glass).controlSize(.small)
                    Button("Use a different key…") { editingKey = true }.controlSize(.small)
                }
            } else if !model.hasKey || editingKey {
                SecureField("API key", text: $keyInput).textFieldStyle(.roundedBorder)
                HStack {
                    Text("Stored in your Mac’s Keychain.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Save key") { model.saveKey(keyInput); keyInput = ""; editingKey = false }.disabled(keyInput.isEmpty)
                }
            } else {
                Button("Change API key…") { editingKey = true }.controlSize(.small)
            }
        }
    }

    private var usageSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            HStack {
                Text("Usage").font(.headline)
                Spacer()
                Text("\(model.budget.requests.formatted()) requests").font(.callout.monospacedDigit())
            }
            Text("\(model.budget.inputTokens.formatted()) input · \(model.budget.outputTokens.formatted()) output tokens")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            // TESTING: Remove the benchmark branch with the benchmark feature.
            Text(String(format: "Approx. $%.4f · %@", model.budget.estimatedUSD,
                        model.benchmarkEnabled || model.benchmarkTrialInProgress
                        ? "Benchmark cap: 30 requests per session" : "No request cap"))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let warning = model.usageWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
        }
    }
}
