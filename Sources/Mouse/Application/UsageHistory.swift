import Foundation
#if SWIFT_PACKAGE
import MouseCore
#endif

/// Disk failures never disable requests. After a failure, keep counting in memory
/// and leave the original file intact rather than repeatedly attempting writes.
struct UsageHistory {
    private let storage = UsageStorage()
    private var canPersist = true

    mutating func load() -> (budget: DemoBudget, warning: String?) {
        do {
            try storage.prepare()
            guard FileManager.default.fileExists(atPath: storage.usageURL.path) else {
                return (DemoBudget(), nil)
            }
            do {
                let data = try Data(contentsOf: storage.usageURL)
                return (try JSONDecoder().decode(DemoBudget.self, from: data), nil)
            } catch {
                // Do not replace unreadable usage until a backup succeeds.
                let backup = storage.usageURL.deletingLastPathComponent()
                    .appendingPathComponent("usage-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: storage.usageURL, to: backup)
                return (DemoBudget(), "Previous usage could not be read. It was preserved in a backup; this counter starts at zero.")
            }
        } catch {
            canPersist = false
            return (DemoBudget(), "Usage history is unavailable. Requests remain enabled; this session counts in memory.")
        }
    }

    /// Returns a new warning only when this write fails; existing warnings remain
    /// visible after later successful writes or while persistence is disabled.
    mutating func save(_ budget: DemoBudget) -> String? {
        guard canPersist else { return nil }
        do {
            try JSONEncoder().encode(budget).write(to: storage.usageURL, options: .atomic)
            return nil
        } catch {
            canPersist = false
            return "Usage could not be saved. Requests remain enabled; this session counts in memory."
        }
    }
}
