import Foundation

/// Prepares Mouse's usage location without replacing any existing counter.
/// The legacy file is copied once and retained as a migration backup.
public struct UsageStorage: Sendable {
    public let usageURL: URL
    private let legacyUsageURL: URL

    public init(applicationSupportDirectory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) {
        usageURL = applicationSupportDirectory
            .appendingPathComponent("Mouse", isDirectory: true)
            .appendingPathComponent("usage.json")
        legacyUsageURL = applicationSupportDirectory
            .appendingPathComponent("Chosen", isDirectory: true)
            .appendingPathComponent("usage.json")
    }

    /// Errors are left to callers, which continue counting in memory without
    /// blocking API requests. copyItem refuses to overwrite an existing file.
    public func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: usageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fileManager.fileExists(atPath: usageURL.path),
              fileManager.fileExists(atPath: legacyUsageURL.path) else { return }
        do {
            try fileManager.copyItem(at: legacyUsageURL, to: usageURL)
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Another process may have created the destination after our check.
            // Keep its counter; never replace it with the legacy snapshot.
            guard fileManager.fileExists(atPath: usageURL.path) else { throw error }
        }
    }
}
