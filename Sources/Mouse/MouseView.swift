import SwiftUI

/// Secondary setup and preferences. The notch is the everyday interface.
struct MouseView: View {
    @ObservedObject var model: AppModel
    @State private var keyInput = ""
    @State private var editingKey = false
    @State private var showDiagnostics = false

    var body: some View {
        NativeGlassSurface {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Mouse").font(.system(size: 30, weight: .semibold)).tracking(-0.8)
                        Text("Your Mac, by voice.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    voiceSection
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
                    DisclosureGroup("Testing & recent activity", isExpanded: $showDiagnostics) {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack {
                                TextField("Type a command", text: $model.command).textFieldStyle(.roundedBorder).onSubmit { model.submit() }
                                Button("Run") { model.submit() }.disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            }
                            ForEach(model.activity.prefix(5)) { item in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.title).font(.callout).textSelection(.enabled)
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }.padding(.top, 12)
                    }.font(.callout)
                }.padding(.horizontal, 28).padding(.top, 48).padding(.bottom, 28)
            }.scrollIndicators(.hidden)
        }
        .ignoresSafeArea()
        .containerBackground(.clear, for: .window)
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.startingVoice ? "Preparing voice…" : model.listening && !model.voice.isRunning ? "Reconnecting microphone…" : model.active ? "Mouse is active" : model.listening ? "Ready for “Hey Mouse”" : "Voice is paused")
                        .font(.headline)
                    Text(model.startingVoice || (model.listening && !model.voice.isRunning) ? model.status : model.active ? "Speak your next command." : "Say “Hey Mouse” to begin.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(model.listening ? "Pause microphone" : "Enable voice") { model.toggleListening() }
                    .buttonStyle(.glass).controlSize(.small)
                    .disabled(model.startingVoice)
            }
            Text("Once activated, Mouse stays ready between commands. Say “stop” to return to standby.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
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
            Text("While active, Luna checks completed speech as text. Accepted commands use screenshots and session history to act. Session history clears when Mouse quits.").font(.caption).foregroundStyle(.secondary)
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
            Text("Luna Fast · text-only speech checks, screenshots for actions. Pauses 1 second between steps. Estimates exclude cache pricing; OpenAI reports actual billing.")
                .font(.caption).foregroundStyle(.secondary)
            if let warning = model.usageWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
        }
    }
}
