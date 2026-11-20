import Foundation
import Speech
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// A completed final-only results stream is the submission barrier. The live
/// analyzer and microphone continue independently while this short local pass runs.
enum SpeechUtteranceFinalizer {
    static func transcribe(_ packets: [SpeechAudioPacket], locale: Locale, timing: PipelineTiming? = nil) async throws -> String {
        let setupSpan = timing?.begin("Local speech analyzer setup")
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["Hey Atmos", "Atmos"]
        do {
            try await analyzer.setContext(context)
            timing?.end(setupSpan, outcome: .succeeded)
        } catch {
            timing?.end(setupSpan, outcome: error is CancellationError ? .cancelled : .failed)
            throw error
        }
        let results = Task {
            var text: [String] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                text.append(String(result.text.characters))
            }
            return text.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return try await withTaskCancellationHandler {
            var stage: PipelineTiming.Span?
            do {
                stage = timing?.begin("Local speech analysis")
                let sequence = AsyncStream<AnalyzerInput> { continuation in
                    for packet in packets { continuation.yield(packet.input) }
                    continuation.finish()
                }
                let lastSample = try await analyzer.analyzeSequence(sequence)
                timing?.end(stage, outcome: .succeeded)
                stage = timing?.begin("Local speech analyzer finalization")
                if let lastSample {
                    try await analyzer.finalizeAndFinish(through: lastSample)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
                timing?.end(stage, outcome: .succeeded)
                // Results are consumed concurrently with analysis. This span
                // measures only the additional wait after analyzer completion.
                stage = timing?.begin("Local speech final results wait")
                let text = try await results.value
                try Task.checkCancellation()
                timing?.end(stage, outcome: .succeeded)
                return text
            } catch {
                timing?.end(stage, outcome: error is CancellationError ? .cancelled : .failed)
                results.cancel()
                let cleanupSpan = timing?.begin("Local speech failure cleanup")
                await analyzer.cancelAndFinishNow()
                timing?.end(cleanupSpan, outcome: .succeeded)
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}
