import SwiftUI

struct ChosenView: View {
    @ObservedObject var model: AppModel
    @State private var keyInput = ""
    var body: some View {
        NativeGlassSurface {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 24) {
                        hero
                        if !model.hasKey || !model.screenAllowed || !model.accessibilityAllowed { setupCard }
                        inputCard
                        if let error = model.error { errorCard(error) }
                        activityCard
                    }.padding(.horizontal, 28).padding(.bottom, 24)
                }.scrollIndicators(.hidden)
                footer
            }
        }
        .ignoresSafeArea()
        .containerBackground(.clear, for: .window)
        .sheet(isPresented: $model.showSettings) { settings }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "waveform.circle.fill").font(.title3).foregroundStyle(.tint)
            Text("Chosen").font(.headline)
            Spacer()
            HStack(spacing: 5) {
                Circle().fill(model.listening ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                Text(model.listening ? "Listening" : "Mic off").font(.caption).foregroundStyle(.secondary)
            }
            Button { model.showSettings = true } label: { Image(systemName: "slider.horizontal.3").frame(width: 28, height: 28) }
                .buttonStyle(.glass).help("Settings").accessibilityLabel("Settings")
        }.padding(.horizontal, 28).padding(.top, 42).padding(.bottom, 18)
    }

    private var hero: some View {
        VStack(spacing: 12) {
            WaveformMark(level: model.audioLevel, active: model.listening || model.working)
                .frame(width: 84, height: 92)
            Text("Your Mac, by voice.").font(.system(size: 29, weight: .semibold, design: .rounded)).tracking(-0.8)
            Text(model.working ? model.status : model.listening ? "Say “Hey Chosen” and what you want to do." : "A little less clicking. A little more doing.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(height: 36)
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { model.toggleListening() } label: {
                        Label(model.listening ? "Pause listening" : "Enable Hey Chosen", systemImage: model.listening ? "mic.slash" : "mic.fill").padding(.horizontal, 8).padding(.vertical, 5)
                    }.buttonStyle(.glassProminent).tint(.accentColor)
                    Button { model.working ? model.cancel() : model.listenNow() } label: {
                        Image(systemName: model.working ? "stop.fill" : "waveform").frame(width: 30, height: 30)
                    }.buttonStyle(.glass).help(model.working ? "Stop immediately" : "Listen now").accessibilityLabel(model.working ? "Stop immediately" : "Listen now")
                }
            }
        }
    }

    private var setupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Make yourself at home").font(.subheadline.weight(.semibold)); Spacer(); Text("SETUP").font(.system(size: 9, weight: .bold)).tracking(1.5).foregroundStyle(.tertiary) }
            if !model.hasKey { permissionRow("OpenAI connection", subtitle: "Your key stays in Keychain", symbol: "key", button: "Connect") { model.showSettings = true } }
            if !model.screenAllowed { permissionRow("See your screen", subtitle: "Only during a command", symbol: "macwindow", button: "Allow") { model.requestScreen() } }
            if !model.accessibilityAllowed { permissionRow("Click and type", subtitle: "Control the app in front of you", symbol: "cursorarrow.click", button: "Allow") { model.requestAccessibility() } }
        }.padding(17).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }

    private func permissionRow(_ title: String, subtitle: String, symbol: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) { Text(title).font(.subheadline); Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button(button, action: action).buttonStyle(.glass).controlSize(.small)
        }
    }

    private var inputCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("OR TYPE A COMMAND").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary); Spacer(); if model.working { ProgressView().controlSize(.mini) } }
            HStack(spacing: 12) {
                TextField("Open Chrome and search YouTube…", text: $model.command)
                    .textFieldStyle(.plain).font(.system(size: 14)).onSubmit { model.submit() }
                    .accessibilityLabel("Command")
                Button { model.submit() } label: { Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold)).frame(width: 27, height: 27) }
                    .buttonStyle(.glassProminent).disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityLabel("Run command")
            }
            if !model.transcript.isEmpty { Text(model.transcript).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }.padding(18).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button { model.error = nil } label: { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).accessibilityLabel("Dismiss error")
        }.padding(14).background(.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    private var activityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RECENT ACTIVITY").font(.system(size: 9, weight: .semibold)).tracking(1.3).foregroundStyle(.secondary)
                Spacer()
                if let duration = model.lastDuration { Text(String(format: "%.1fs", duration)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary) }
            }
            if model.activity.isEmpty {
                VStack(spacing: 9) {
                    Text("Start with something simple.").font(.subheadline).foregroundStyle(.secondary)
                    HStack(spacing: 7) {
                        suggestion("Open Chrome", symbol: "globe")
                        suggestion("Go fullscreen", symbol: "arrow.up.left.and.arrow.down.right")
                    }
                }.frame(maxWidth: .infinity).padding(.vertical, 16)
            } else {
                ForEach(model.activity.prefix(4)) { item in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.symbol).font(.system(size: 13)).foregroundStyle(item.detail == "Completed" ? Color.green : Color.secondary).frame(width: 18).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) { Text(item.title).font(.subheadline).lineLimit(2); Text(item.detail).font(.caption2).foregroundStyle(.tertiary) }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
    private func suggestion(_ text: String, symbol: String) -> some View {
        Button { model.command = text } label: { Label(text, systemImage: symbol).font(.caption).padding(.vertical, 2) }.buttonStyle(.glass)
    }
    private var footer: some View {
        VStack(spacing: 8) {
            Divider().opacity(0.4)
            HStack {
                Label("\(model.budget.requests) requests", systemImage: "arrow.up.arrow.down")
                Spacer()
                Text(String(format: "~$%.4f", model.budget.estimatedUSD))
            }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            HStack {
                Text("\(model.budget.inputTokens.formatted()) in · \(model.budget.outputTokens.formatted()) out tokens")
                Spacer()
                Text("No request cap")
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            if let warning = model.usageWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.caption2).foregroundStyle(.orange).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(.horizontal, 28).padding(.bottom, 20)
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack { Text("Chosen Settings").font(.title2.weight(.semibold)); Spacer(); Button("Done") { model.showSettings = false }.buttonStyle(.glass) }
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Label(model.hasKey ? "Connected through Keychain" : "Connect OpenAI", systemImage: "key.fill").font(.headline)
                    SecureField("OpenAI API key", text: $keyInput).textFieldStyle(.roundedBorder)
                    HStack { Text("GPT-6 Luna · Fast · Low reasoning").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save key") { model.saveKey(keyInput); keyInput = "" }.disabled(keyInput.isEmpty) }
                }.padding(8)
            }
            Toggle("Launch Chosen at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
            VStack(alignment: .leading, spacing: 8) {
                Text("“Hey Chosen” wakes a 20-second command session.").font(.subheadline)
                Text("Say “stop” to cancel. Follow-up commands work without repeating the wake phrase. Voice recognition stays on this Mac; screenshots and commands go to OpenAI when you ask Chosen to act.").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack { Text("Usage counter"); Spacer(); Text("\(model.budget.requests) requests").monospacedDigit() }
            HStack { Text("Input tokens"); Spacer(); Text(model.budget.inputTokens.formatted()).monospacedDigit() }.font(.subheadline)
            HStack { Text("Output tokens"); Spacer(); Text(model.budget.outputTokens.formatted()).monospacedDigit() }.font(.subheadline)
            Text(String(format: "Estimated API usage: $%.4f. Chosen has no request or spending cap. Failed and cancelled attempts count; token totals include usage returned by the model. Your OpenAI project controls billing. Commands pause after 8 model turns.", model.budget.estimatedUSD)).font(.caption).foregroundStyle(.secondary)
            if let warning = model.usageWarning { Text(warning).font(.caption).foregroundStyle(.orange) }
            HStack {
                Button("Screen Recording…") { model.openPrivacy("Privacy_ScreenCapture") }
                Button("Accessibility…") { model.openPrivacy("Privacy_Accessibility") }
            }.controlSize(.small)
        }.padding(26).frame(width: 440)
    }
}

private struct WaveformMark: View {
    let level: Double
    let active: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.08, paused: !active)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<7) { index in
                    let wave = active ? (sin(time * 4 + Double(index) * 0.8) + 1) / 2 : 0.35
                    let envelope = 1 - abs(Double(index) - 3) / 4
                    Capsule().fill(LinearGradient(colors: [.cyan, .blue.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 4, height: 10 + envelope * (12 + wave * 12 + min(level, 1) * 15))
                }
            }.frame(width: 64, height: 64)
        }.accessibilityHidden(true)
    }
}
