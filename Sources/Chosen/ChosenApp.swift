import AppKit
import SwiftUI
import Speech
#if SWIFT_PACKAGE
import ChosenCore
#endif

@main
enum ChosenEntry {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--import-key") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                try KeychainStore.save(String(data: data, encoding: .utf8) ?? "")
                print("API key stored in macOS Keychain.")
                exit(0)
            } catch { fputs("Keychain import failed.\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--diagnostics") {
            let native = NativeComputer()
            print("Mouse native interface")
            print("Key configured: \(KeychainStore.exists())")
            print("Screen Recording: \(native.screenRecordingGranted)")
            print("Accessibility: \(native.accessibilityGranted)")
            print("Model: gpt-6-luna / Fast / low reasoning")
            print("On-device English speech: \(SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.supportsOnDeviceRecognition ?? false)")
            print("Speech authorization: \(SFSpeechRecognizer.authorizationStatus().rawValue)")
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--voice-check") {
            guard index + 1 < CommandLine.arguments.count else {
                fputs("Usage: Chosen --voice-check /path/to/audio-file\n", stderr); exit(1)
            }
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            _ = NSApplication.shared
            Task { @MainActor in
                do {
                    let report = try await VoiceFileCheck.run(url: url)
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    print(String(decoding: try encoder.encode(report), as: UTF8.self))
                    exit(report.passed ? 0 : 1)
                } catch { print("Voice check failed: \(error.localizedDescription)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if CommandLine.arguments.contains("--api-check") {
            let key = CommandLine.arguments.contains("--key-stdin")
                ? String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                : nil
            _ = NSApplication.shared
            Task { @MainActor in
                do { try await APICheck.run(apiKey: key); exit(0) }
                catch { print("API check failed: \(error.localizedDescription)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--notch-preview") {
            let state = index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : "active"
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.accessory)
            let overlay = MouseNotchController()
            Task { @MainActor in
                let transcript = "Go to Chrome, open up YouTube and then go search Linus Tech Tips, go to his channel, and click on his store link in his profile"
                switch state {
                case "standby": overlay.show(.standby)
                case "transcript": overlay.show(.transcribing(transcript))
                case "action": overlay.show(.working("Opening store…"))
                case "notice": overlay.show(.notice("Which channel did you mean?"))
                case "cycle":
                    let states: [MouseOverlayState] = [.active, .transcribing("Go to Chrome"), .transcribing(transcript), .working("Going to Chrome…"), .working("Searching YouTube…"), .working("Searching Linus Tech Tips…"), .working("Opening channel…"), .working("Opening store…"), .active]
                    for item in states {
                        overlay.show(item)
                        try? await Task.sleep(for: .seconds(2))
                    }
                default: overlay.show(.active)
                }
            }
            NSApp.run()
            return
        }
        ChosenApplication.main()
    }
}

struct ChosenApplication: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Mouse Settings", id: "settings") {
            ChosenView(model: model)
                .frame(width: 490, height: 650)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 490, height: 650)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        MenuBarExtra {
            MouseMenu(model: model)
        } label: {
            MouseMenuLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MouseMenuLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var didLaunch = false
    var body: some View {
        Image(systemName: model.listening ? "cursorarrow" : "mic.slash")
            .accessibilityLabel("Mouse")
            .onAppear {
                guard !didLaunch else { return }
                didLaunch = true
                model.startStandby()
                if model.needsSetup { openWindow(id: "settings"); NSApp.activate() }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                model.cancel(silent: true)
                model.voice.stop()
            }
    }
}

private struct MouseMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.working ? model.status : model.active ? "Mouse is active" : model.listening ? "Waiting for Hey Mouse" : "Microphone paused")
        Divider()
        Button(model.active || model.working ? "Stop Mouse" : "Activate Mouse") {
            if model.active || model.working { model.sleep() } else { model.listenNow() }
        }
        Divider()
        Button("Settings…") { openWindow(id: "settings"); NSApp.activate() }.keyboardShortcut(",")
        Button(model.listening ? "Pause microphone" : "Resume microphone") { model.toggleListening() }
        Divider()
        Button("Quit Mouse") { model.cancel(silent: true); model.voice.stop(); NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
