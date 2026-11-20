import AppKit
import SwiftUI
import Speech
import AVFoundation
#if SWIFT_PACKAGE
import MouseCore
#endif

@main
enum MouseEntry {
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
            let preferences = MousePreferences.load()
            print("Models: \(preferences.behavior.title) · 1000 ms between steps")
            print("Audio sensitivity: \(Int(preferences.audioSensitivity * 100))% · second transcription pass: \(preferences.secondPassEnabled ? "on" : "off")")
            print("Key readable by this build: \((try? KeychainStore.load()) != nil)")
            print("Speech engine: Apple SpeechAnalyzer / SpeechTranscriber (on-device)")
            print("SpeechTranscriber available: \(SpeechTranscriber.isAvailable)")
            print("Microphone authorization: \(AVCaptureDevice.authorizationStatus(for: .audio).rawValue)")
            exit(0)
        }
        if CommandLine.arguments.contains("--microphone-check") {
            _ = NSApplication.shared
            Task { @MainActor in
                do { try await MicrophoneCheck.run(); exit(0) }
                catch { print("Microphone check failed: \(error.localizedDescription)"); exit(1) }
            }
            NSApplication.shared.run()
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--voice-check") {
            guard index + 1 < CommandLine.arguments.count else {
                fputs("Usage: Mouse --voice-check /path/to/audio-file\n", stderr); exit(1)
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
                case "thinking": overlay.show(.thinking)
                case "notice": overlay.show(.notice("Which channel did you mean?"))
                case "cycle":
                    let states: [MouseOverlayState] = [.active, .transcribing("Go to Chrome"), .transcribing(transcript), .thinking, .working("Going to Chrome…"), .thinking, .working("Searching YouTube…"), .working("Searching Linus Tech Tips…"), .working("Opening channel…"), .working("Opening store…"), .active]
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
        MouseApplication.main()
    }
}

struct MouseApplication: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("Mouse Settings", id: "settings") {
            MouseView(model: model)
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

