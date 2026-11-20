import Foundation
import Speech

/// Shared setup for live recognition and the supplied-file diagnostic. Download
/// policy is explicit so read-only checks never install models as a side effect.
@MainActor
enum SpeechRuntimeSetup {
    enum SetupError: LocalizedError {
        case unavailable
        case unsupportedEnglish
        case assetsMissing
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "Apple's new speech transcriber is unavailable on this Mac."
            case .unsupportedEnglish: return "Apple's speech transcriber does not support US English on this Mac."
            case .assetsMissing: return "The US English speech model is not installed. Enable the microphone in Atmos to download it."
            case .installationFailed(let reason): return "Could not install the US English speech model: \(reason)"
            }
        }
    }

    static func supportedEnglishLocale() async throws -> Locale {
        guard SpeechTranscriber.isAvailable else { throw SetupError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            throw SetupError.unsupportedEnglish
        }
        return locale
    }

    static func ensureAssets(
        for modules: [any SpeechModule],
        locale: Locale,
        allowsDownload: Bool,
        onStatus: ((String) -> Void)? = nil
    ) async throws {
        try Task.checkCancellation()
        // Reservation is per client; establish it before asking asset status.
        try await AssetInventory.reserve(locale: locale)
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else { throw SetupError.unsupportedEnglish }
        if status == .installed { return }
        guard allowsDownload else { throw SetupError.assetsMissing }
        onStatus?("Downloading US English speech model…")
        do {
            guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else {
                guard await AssetInventory.status(forModules: modules) == .installed else { throw SetupError.assetsMissing }
                return
            }
            let progressTask = Task { @MainActor in
                var previousPercent = -1
                while !Task.isCancelled {
                    let percent = Int(max(0, min(1, request.progress.fractionCompleted)) * 100)
                    if percent != previousPercent {
                        previousPercent = percent
                        onStatus?("Downloading US English speech model… \(percent)%")
                    }
                    do { try await Task.sleep(for: .milliseconds(250)) }
                    catch { return }
                }
            }
            defer { progressTask.cancel() }
            try await withTaskCancellationHandler {
                try await request.downloadAndInstall()
            } onCancel: {
                request.progress.cancel()
            }
            try Task.checkCancellation()
            guard await AssetInventory.status(forModules: modules) == .installed else { throw SetupError.assetsMissing }
            onStatus?("Preparing speech recognition…")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SetupError.installationFailed(error.localizedDescription)
        }
    }
}
