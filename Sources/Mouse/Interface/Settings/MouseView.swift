import SwiftUI

/// Secondary setup, action history, and full answers. The notch is the everyday interface.
struct MouseView: View {
    private enum Tab: String, CaseIterable {
        case settings = "Settings"
        case actions = "Actions"
        case answers = "Answers"
    }

    @ObservedObject var model: AppModel
    @State private var selectedTab = Tab.settings
    @State private var keyInput = ""
    @State private var editingKey = false

    var body: some View {
        NativeGlassSurface {
            VStack(spacing: 20) {
                // Keep navigation above the scroll view so history remains easy
                // to reach even when the settings or action payloads are long.
                Picker("Window section", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 28)
                .padding(.top, 48)

                switch selectedTab {
                case .settings:
                    settingsContent
                case .actions:
                    ActionHistoryView(model: model)
                case .answers:
                    QuestionAnswersView(model: model)
                }
            }
        }
        .ignoresSafeArea()
        .containerBackground(.clear, for: .window)
    }

    private var settingsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                voiceSection
                BehaviorSettingsView(model: model)
                permissionsSection
                connectionSection
                Toggle("Open Mouse at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                    .toggleStyle(.switch)
                if let error = model.error {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Needs attention", systemImage: "exclamationmark.circle").font(.subheadline.weight(.medium))
                        Text(error).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                        Button("Dismiss") { model.error = nil }.controlSize(.small)
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                }
                usageSection
                ActivityDiagnosticsView(model: model)
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }.scrollIndicators(.hidden)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(voiceTitle).font(.headline)
                Spacer()
                Button(model.listening ? "Pause microphone" : "Enable voice") { model.toggleListening() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(model.startingVoice)
            }
        }
    }

    private var voiceTitle: String {
        if model.startingVoice { return "Preparing voice…" }
        if model.listening && !model.voice.isRunning { return "Reconnecting microphone…" }
        if model.active { return "Active" }
        return model.listening ? "Standby" : "Microphone paused"
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mac permissions").font(.headline)
            permission("Screen Recording", detail: "See the screen during a command", symbol: "macwindow", allowed: model.screenAllowed) { model.requestScreen() }
            Divider()
            permission("Accessibility", detail: "Click, type, and use shortcuts", symbol: "cursorarrow", allowed: model.accessibilityAllowed) { model.requestAccessibility() }
            Divider()
            permission("Microphone", detail: "Voice recognition stays on this Mac", symbol: "mic", allowed: model.voiceAuthorized) { if !model.listening { model.toggleListening() } }
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
            Text(String(format: "Approx. $%.4f · No request cap", model.budget.estimatedUSD)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if let warning = model.usageWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
        }
    }
}
