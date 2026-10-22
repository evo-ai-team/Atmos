import Foundation
import XCTest
@testable import MouseCore

final class MousePreferencesTests: XCTestCase {
    func testAbsentPreferencesPreserveExistingDefaults() {
        withDefaults { defaults in
            XCTAssertEqual(MousePreferences.load(from: defaults), MousePreferences())
            XCTAssertEqual(MousePreferences.load(from: defaults).behavior, .decisionsTextOnly)
            XCTAssertTrue(MousePreferences.load(from: defaults).secondPassEnabled)
        }
    }

    func testAllModesAndAudioChoicesSurviveReload() {
        withDefaults { defaults in
            for behavior in ChatbotBehavior.allCases {
                let preferences = MousePreferences(behavior: behavior, audioSensitivity: 0.8, secondPassEnabled: false)
                preferences.save(to: defaults)
                XCTAssertEqual(MousePreferences.load(from: defaults), preferences)
            }
        }
    }

    func testInvalidStoredValuesHaveSafeDefaultsAndBoundedSensitivity() {
        withDefaults { defaults in
            defaults.set("unknown-mode", forKey: "mouse.chatbotBehavior")
            defaults.set(2.5, forKey: "mouse.audioSensitivity")
            XCTAssertEqual(MousePreferences.load(from: defaults).behavior, .decisionsTextOnly)
            XCTAssertEqual(MousePreferences.load(from: defaults).audioSensitivity, 1)
            XCTAssertEqual(MousePreferences(audioSensitivity: -.infinity).audioSensitivity, 0.5)
            XCTAssertEqual(MousePreferences(audioSensitivity: -1).audioSensitivity, 0)
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "MousePreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
