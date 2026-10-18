import AVFoundation
import Foundation
import Speech
#if SWIFT_PACKAGE
import ChosenCore
#endif

/// A diagnostic path for the packaged app's own TCC identity. It only reads a
/// supplied audio file and exercises local ASR plus the wake-command boundary.
@MainActor
enum VoiceFileCheck {
    struct Report: Codable {
        let passed: Bool
        let transcript: String
        let emittedCommands: [String]
        let expectedCommand: String
        let locale: String
        let onDevice: Bool
        let microphoneAuthorization: String
        let speechAuthorization: String
    }

    enum CheckError: LocalizedError {
        case invalidFile
        case notAuthorized(String)
        case unavailable
        case timedOut
        case emptyTranscript
        case recognitionFailed(String, Int, String)

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Voice check needs a readable local audio file."
            case .notAuthorized(let status): return "Speech authorization is \(status). Enable Voice in Chosen first; this check never requests permission."
            case .unavailable: return "On-device en-US speech recognition is unavailable."
            case .timedOut: return "Local speech recognition did not finish within 30 seconds."
            case .emptyTranscript: return "Local speech recognition returned no transcript."
            case .recognitionFailed(let domain, let code, let message): return "Local speech recognition failed (\(domain) \(code)): \(message)"
            }
        }
    }

    /// Expected fixture: "Hey Chosen, open Chrome." No microphone capture,
    /// permission prompt, screen access, input event, credential, or API request.
    static func run(url: URL) async throws -> Report {
        try Task.checkCancellation()
        guard url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CheckError.invalidFile
        }
        let authorization = SFSpeechRecognizer.authorizationStatus()
        guard authorization == .authorized else {
            throw CheckError.notAuthorized(speechStatus(authorization))
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.supportsOnDeviceRecognition, recognizer.isAvailable else {
            throw CheckError.unavailable
        }

        let recognition = FileRecognition(recognizer: recognizer)
        let transcript = try await recognition.transcribe(url: url)
        try Task.checkCancellation()
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CheckError.emptyTranscript
        }

        var session = WakeSession()
        let beforeSilence = session.receive(transcript, at: 0)
        let afterSilence = session.finishUtterance(at: 1)
        let premature = commands(in: beforeSilence)
        let emitted = commands(in: afterSilence)
        let expected = "open Chrome"
        let passed = premature.isEmpty && emitted.count == 1 && normalized(emitted[0]) == normalized(expected)
        return Report(
            passed: passed,
            transcript: transcript,
            emittedCommands: premature + emitted,
            expectedCommand: expected,
            locale: recognizer.locale.identifier,
            onDevice: true,
            microphoneAuthorization: microphoneStatus(AVCaptureDevice.authorizationStatus(for: .audio)),
            speechAuthorization: speechStatus(authorization)
        )
    }

    private static func commands(in events: [WakeSession.Event]) -> [String] {
        events.compactMap { event in
            if case .command(let command) = event { return command }
            return nil
        }
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func speechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    private static func microphoneStatus(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "unknown"
        }
    }

    @MainActor
    private final class FileRecognition {
        private let recognizer: SFSpeechRecognizer
        private var task: SFSpeechRecognitionTask?
        private var timeoutTask: Task<Void, Never>?
        private var continuation: CheckedContinuation<String, Error>?

        init(recognizer: SFSpeechRecognizer) { self.recognizer = recognizer }

        func transcribe(url: URL) async throws -> String {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    self.continuation = continuation
                    let request = SFSpeechURLRecognitionRequest(url: url)
                    request.requiresOnDeviceRecognition = true
                    request.shouldReportPartialResults = false
                    request.addsPunctuation = false
                    request.taskHint = .dictation
                    request.contextualStrings = ["Hey Chosen", "Chosen"]
                    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                        let transcript = result?.bestTranscription.formattedString
                        let isFinal = result?.isFinal == true
                        let failure = error.map { error -> CheckError in
                            let nsError = error as NSError
                            return .recognitionFailed(nsError.domain, nsError.code, nsError.localizedDescription)
                        }
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            if isFinal, let transcript {
                                self.finish(.success(transcript))
                            } else if let failure {
                                self.finish(.failure(failure))
                            }
                        }
                    }
                    timeoutTask = Task { @MainActor [weak self] in
                        do { try await Task.sleep(for: .seconds(30)) }
                        catch { return }
                        self?.finish(.failure(CheckError.timedOut))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
            }
        }

        private func finish(_ result: Result<String, Error>) {
            guard let continuation else { return }
            self.continuation = nil
            timeoutTask?.cancel()
            timeoutTask = nil
            task?.cancel()
            task = nil
            continuation.resume(with: result)
        }
    }
}
