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
            print("Chosen native demo")
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
        ChosenApplication.main()
    }
}

struct ChosenApplication: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Chosen", id: "main") {
            ChosenView(model: model)
                .frame(minWidth: 480, idealWidth: 520, maxWidth: 680, minHeight: 620, idealHeight: 700)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel(silent: true); model.voice.stop() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultSize(width: 520, height: 700)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Chosen Settings…") { model.showSettings = true }.keyboardShortcut(",")
            }
            CommandMenu("Voice") {
                Button(model.listening ? "Turn Microphone Off" : "Enable Hey Chosen") { model.toggleListening() }
                Button("Listen Now") { model.listenNow() }.keyboardShortcut(" ", modifiers: [.command, .shift])
                Button("Stop") { model.cancel() }.keyboardShortcut(".", modifiers: .command)
            }
        }
        MenuBarExtra {
            ChosenMenu(model: model)
        } label: {
            Label("Chosen", systemImage: model.working ? "cursorarrow.rays" : model.listening ? "waveform" : "waveform.slash")
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct ChosenMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text(model.status)
        Divider()
        Button(model.listening ? "Microphone Off" : "Enable Hey Chosen") { model.toggleListening() }
        Button("Listen Now") { model.listenNow() }
        Button("Stop Current Action") { model.cancel() }.disabled(!model.working)
        Divider()
        Button("Open Chosen") { openWindow(id: "main"); NSApp.activate() }
        Button("Quit Chosen") { model.cancel(); model.voice.stop(); NSApp.terminate(nil) }
    }
}
