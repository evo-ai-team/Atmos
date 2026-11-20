import AppKit
import AVFoundation

/// Finite check of the production microphone/transcriber path. Counts signal
/// and previews only; never saves audio/text, loads a key, or executes commands.
@MainActor enum MicrophoneCheck {
    static func run() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            print("Microphone check needs Mouse's existing microphone permission. Enable voice in Mouse Settings first.")
            return
        }
        let voice = VoiceInput()
        var levelUpdates = 0
        var peakLevel = 0.0
        var previews = 0
        var failure: String?
        voice.onLevel = { level in
            levelUpdates += 1
            peakLevel = max(peakLevel, level)
        }
        voice.onPartial = { text in if !text.isEmpty { previews += 1 } }
        voice.onFailure = { failure = $0 }
        defer { voice.stop() }
        try await voice.start()
        // The diagnostic has no command handler or computer-control model.
        // Activation lets us count real live previews without needing a wake phrase.
        voice.activate()
        try await Task.sleep(for: .seconds(8))
        let running = voice.isRunning
        voice.stop()
        let report: [String: Any] = [
            "inputMode": "normal microphone input; app voice processing disabled",
            "engineRunningAtEnd": running,
            "levelUpdates": levelUpdates,
            "peakNormalizedLevel": peakLevel,
            "nonzeroSignalReceived": peakLevel > 0,
            "livePreviewUpdates": previews,
            "failure": failure ?? "",
            "audioSaved": false,
            "transcriptSaved": false,
            "apiUsed": false,
            "desktopActionsExecuted": false
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
