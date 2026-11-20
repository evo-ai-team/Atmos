import AppKit
import SwiftUI
import Speech
import AVFoundation
#if SWIFT_PACKAGE
import AtmosCore
#endif

@main
enum AtmosEntry {
    @MainActor static func main() {
        let importKrisp = CommandLine.arguments.contains("--import-krisp-key")
        if importKrisp || CommandLine.arguments.contains("--import-key") {
            do {
                let data = FileHandle.standardInput.readDataToEndOfFile()
                let store: KeychainStore = importKrisp ? .krisp : .openAI
                try store.save(String(data: data, encoding: .utf8) ?? "")
                if importKrisp {
                    var preferences = AtmosPreferences.load()
                    preferences.vivaProEnabled = true
                    preferences.save()
                }
                print("API key stored in macOS Keychain.")
                exit(0)
            } catch { fputs("Keychain import failed.\n", stderr); exit(1) }
        }
        if CommandLine.arguments.contains("--diagnostics") {
            let native = NativeComputer()
            print("Atmos native interface")
            print("Key configured: \(KeychainStore.openAI.exists())")
            print("Screen Recording: \(native.screenRecordingGranted)")
            print("Accessibility: \(native.accessibilityGranted)")
            let preferences = AtmosPreferences.load()
            print("Models: \(preferences.behavior.title) · 1000 ms between steps")
            print("Audio sensitivity: \(Int(preferences.audioSensitivity * 100))% · second transcription pass: \(preferences.secondPassEnabled ? "on" : "off")")
            print("Key readable by this build: \((try? KeychainStore.openAI.load()) != nil)")
            print("VIVA Pro: \(preferences.vivaProEnabled ? "enabled" : "off") · Krisp key readable: \((try? KeychainStore.krisp.load()) != nil)")
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
                fputs("Usage: Atmos --voice-check /path/to/audio-file\n", stderr); exit(1)
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
            let overlay = AtmosNotchController()
            Task { @MainActor in
                let transcript = "Go to Chrome, open up YouTube and then go search Linus Tech Tips, go to his channel, and click on his store link in his profile"
                switch state {
                case "standby": overlay.show(.standby)
                case "transcript": overlay.show(.transcribing(transcript))
                case "action": overlay.show(.working("Opening store…"))
                case "thinking": overlay.show(.thinking)
                case "notice": overlay.show(.notice("Which channel did you mean?"))
                case "cycle":
                    let states: [AtmosOverlayState] = [.active, .transcribing("Go to Chrome"), .transcribing(transcript), .thinking, .working("Going to Chrome…"), .thinking, .working("Searching YouTube…"), .working("Searching Linus Tech Tips…"), .working("Opening channel…"), .working("Opening store…"), .active]
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
        AtmosApplication.main()
    }
}

struct AtmosApplication: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            AtmosMenu(model: model)
        } label: {
            AtmosMenuLabel(model: model)
        }
        .menuBarExtraStyle(.menu)
    }
}

