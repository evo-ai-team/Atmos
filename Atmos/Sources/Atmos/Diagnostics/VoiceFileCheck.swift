import AVFoundation
import Foundation
import CoreMedia
import Speech
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// Transcribes a supplied file with the same modern on-device model used by
/// live voice input. It never opens the microphone or sends a command to the API.
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
        let engine: String
        let model: String
        let finalizedSegments: Int
        let assets: String
        let inputEndSeconds: Double?
        let resultTimings: [ResultTiming]
    }

    struct ResultTiming: Codable, Sendable {
        let startSeconds: Double?
        let endSeconds: Double?
        let finalizedThroughSeconds: Double?
    }

    enum CheckError: LocalizedError {
        case invalidFile
        case timedOut
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .invalidFile: return "Voice check needs a readable local audio file."
            case .timedOut: return "SpeechAnalyzer did not finish the file within 30 seconds."
            case .emptyTranscript: return "SpeechTranscriber returned no finalized transcript."
            }
        }
    }

    /// Expected fixture: "Hey Atmos, open Chrome."
    /// File analysis requires neither microphone nor legacy Speech authorization.
    /// Install model assets separately unless this invocation explicitly permits it.
    static func run(url: URL, allowsDownload: Bool = false) async throws -> Report {
        try Task.checkCancellation()
        guard url.isFileURL,
              FileManager.default.isReadableFile(atPath: url.path),
              (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw CheckError.invalidFile
        }
        let file = try AVAudioFile(forReading: url)
        guard file.length > 0 else { throw CheckError.invalidFile }
        let locale = try await SpeechRuntimeSetup.supportedEnglishLocale()
        // .transcription is the shipping SDK name for the final-results file preset.
        // It uses SpeechTranscriber, not the older dictation model.
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        try await SpeechRuntimeSetup.ensureAssets(for: [transcriber], locale: locale, allowsDownload: allowsDownload)
        try Task.checkCancellation()
        let assets = await AssetInventory.status(forModules: [transcriber])

        let result = try await transcribe(file: file, using: transcriber)
        let transcript = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else { throw CheckError.emptyTranscript }

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
            locale: locale.identifier(.bcp47),
            onDevice: true,
            microphoneAuthorization: "notRequiredForFile",
            speechAuthorization: "notRequired",
            engine: "SpeechAnalyzer",
            model: "SpeechTranscriber",
            finalizedSegments: result.segments,
            assets: String(describing: assets),
            inputEndSeconds: result.inputEndSeconds,
            resultTimings: result.timings
        )
    }

    private struct FileTranscript: Sendable {
        let text: String
        let segments: Int
        let timings: [ResultTiming]
        var inputEndSeconds: Double?
    }

    private enum FileOutcome: Sendable {
        case completed(FileTranscript)
        case timedOut
    }

    private static func transcribe(file: AVAudioFile, using transcriber: SpeechTranscriber) async throws -> FileTranscript {
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return try await withThrowingTaskGroup(of: FileOutcome.self) { group in
            group.addTask {
                try await withTaskCancellationHandler {
                    // Consume results concurrently with input. Finalization closes the
                    // stream; awaiting the consumer drains every published final result.
                    async let transcript = collectFinalResults(from: transcriber)
                    do {
                        let lastSample = try await analyzer.analyzeSequence(from: file)
                        if let lastSample {
                            try await analyzer.finalizeAndFinish(through: lastSample)
                        } else {
                            await analyzer.cancelAndFinishNow()
                        }
                        var result = try await transcript
                        result.inputEndSeconds = lastSample.flatMap { $0.seconds.isFinite ? $0.seconds : nil }
                        return .completed(result)
                    } catch {
                        await analyzer.cancelAndFinishNow()
                        throw error
                    }
                } onCancel: {
                    // Cancelling a result consumer alone need not end its analyzer.
                    // Explicitly finish it so task-group cleanup cannot strand a stream.
                    Task { await analyzer.cancelAndFinishNow() }
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                return .timedOut
            }
            do {
                guard let outcome = try await group.next() else { throw CancellationError() }
                group.cancelAll()
                switch outcome {
                case .completed(let transcript):
                    try Task.checkCancellation()
                    return transcript
                case .timedOut:
                    await analyzer.cancelAndFinishNow()
                    throw CheckError.timedOut
                }
            } catch {
                group.cancelAll()
                await analyzer.cancelAndFinishNow()
                throw error
            }
        }
    }

    private static func collectFinalResults(from transcriber: SpeechTranscriber) async throws -> FileTranscript {
        var text = ""
        var count = 0
        var timings: [ResultTiming] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            text += String(result.text.characters)
            count += 1
            let start = result.range.start.seconds
            let end = CMTimeRangeGetEnd(result.range).seconds
            let finalized = result.resultsFinalizationTime.seconds
            timings.append(ResultTiming(
                startSeconds: start.isFinite ? start : nil,
                endSeconds: end.isFinite ? end : nil,
                finalizedThroughSeconds: finalized.isFinite ? finalized : nil
            ))
        }
        try Task.checkCancellation()
        return FileTranscript(text: text, segments: count, timings: timings, inputEndSeconds: nil)
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
}
