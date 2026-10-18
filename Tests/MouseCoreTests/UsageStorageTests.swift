import Foundation
import XCTest
@testable import MouseCore

final class UsageStorageTests: XCTestCase {
    func testCopiesExistingCounterAndPreservesLegacyFile() throws {
        try withTemporarySupportDirectory { directory in
            let legacyURL = directory.appendingPathComponent("Chosen/usage.json")
            var budget = DemoBudget()
            budget.requests = 398
            budget.inputTokens = 1_880_000
            budget.outputTokens = 15_000
            let original = try JSONEncoder().encode(budget)
            try write(original, to: legacyURL)

            let storage = UsageStorage(applicationSupportDirectory: directory)
            try storage.prepare()

            let migratedData = try Data(contentsOf: storage.usageURL)
            let migrated = try JSONDecoder().decode(DemoBudget.self, from: migratedData)
            XCTAssertEqual(storage.usageURL, directory.appendingPathComponent("Mouse/usage.json"))
            XCTAssertEqual(migrated.requests, 398)
            XCTAssertEqual(migrated.inputTokens, 1_880_000)
            XCTAssertEqual(migrated.outputTokens, 15_000)
            XCTAssertEqual(migratedData, original)
            XCTAssertEqual(try Data(contentsOf: legacyURL), original)
        }
    }

    func testNeverOverwritesExistingMouseCounter() throws {
        try withTemporarySupportDirectory { directory in
            let storage = UsageStorage(applicationSupportDirectory: directory)
            let legacyURL = directory.appendingPathComponent("Chosen/usage.json")
            let legacy = Data(#"{"requests":398,"inputTokens":1880000,"outputTokens":15000}"#.utf8)
            let current = Data(#"{"requests":499,"inputTokens":2000000,"outputTokens":20000}"#.utf8)
            try write(legacy, to: legacyURL)
            try write(current, to: storage.usageURL)

            try storage.prepare()
            try storage.prepare()

            XCTAssertEqual(try Data(contentsOf: storage.usageURL), current)
            XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)
        }
    }

    func testFreshInstallCreatesOnlyMouseDirectory() throws {
        try withTemporarySupportDirectory { directory in
            let storage = UsageStorage(applicationSupportDirectory: directory)
            try storage.prepare()

            var isDirectory: ObjCBool = false
            XCTAssertTrue(FileManager.default.fileExists(atPath: storage.usageURL.deletingLastPathComponent().path, isDirectory: &isDirectory))
            XCTAssertTrue(isDirectory.boolValue)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.usageURL.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("Chosen").path))
        }
    }

    func testMigrationFailureLeavesLegacyCounterIntact() throws {
        try withTemporarySupportDirectory { directory in
            let legacyURL = directory.appendingPathComponent("Chosen/usage.json")
            let legacy = Data(#"{"requests":398,"inputTokens":1880000,"outputTokens":15000}"#.utf8)
            try write(legacy, to: legacyURL)
            // A file at the directory path forces a deterministic preparation error
            // without relying on permissions or the test process's effective user.
            let blockedDirectory = directory.appendingPathComponent("Mouse")
            let blocker = Data("existing file".utf8)
            try blocker.write(to: blockedDirectory)
            let storage = UsageStorage(applicationSupportDirectory: directory)

            XCTAssertThrowsError(try storage.prepare())
            XCTAssertEqual(try Data(contentsOf: legacyURL), legacy)
            XCTAssertEqual(try Data(contentsOf: blockedDirectory), blocker)
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func withTemporarySupportDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouse-usage-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}
