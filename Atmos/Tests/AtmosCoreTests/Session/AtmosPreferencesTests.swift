import Foundation
import XCTest
@testable import AtmosCore

final class AtmosPreferencesTests: XCTestCase {
    func testAbsentPreferencesPreserveExistingDefaults() {
        withDefaults { defaults in
            XCTAssertEqual(AtmosPreferences.load(from: defaults), AtmosPreferences())
            XCTAssertEqual(AtmosPreferences.load(from: defaults).behavior, .decisionsTextOnly)
            XCTAssertTrue(AtmosPreferences.load(from: defaults).secondPassEnabled)
            XCTAssertFalse(AtmosPreferences.load(from: defaults).vivaProEnabled)
            XCTAssertFalse(AtmosPreferences.load(from: defaults).microphoneMuted)
            XCTAssertTrue(AtmosPreferences.load(from: defaults).displayTapsEnabled)
        }
    }

    func testAllModesAndAudioChoicesSurviveReload() {
        withDefaults { defaults in
            for behavior in ChatbotBehavior.allCases {
                let preferences = AtmosPreferences(behavior: behavior, audioSensitivity: 0.8, secondPassEnabled: false,
                                                   vivaProEnabled: true, displayTapsEnabled: false, displayTapThreshold: 0.01,
                                                   microphoneMuted: true)
                preferences.save(to: defaults)
                XCTAssertEqual(AtmosPreferences.load(from: defaults), preferences)
            }
        }
    }

    func testInvalidStoredValuesHaveSafeDefaultsAndBoundedSensitivity() {
        withDefaults { defaults in
            defaults.set("unknown-mode", forKey: "atmos.chatbotBehavior")
            defaults.set(2.5, forKey: "atmos.audioSensitivity")
            XCTAssertEqual(AtmosPreferences.load(from: defaults).behavior, .decisionsTextOnly)
            XCTAssertEqual(AtmosPreferences.load(from: defaults).audioSensitivity, 1)
            XCTAssertEqual(AtmosPreferences(audioSensitivity: -.infinity).audioSensitivity, 0.5)
            XCTAssertEqual(AtmosPreferences(audioSensitivity: -1).audioSensitivity, 0)
        }
    }

    func testCalibratedTimingAndManualSensitivityPersistIndependently() {
        withDefaults { defaults in
            let profile = DisplayTapProfile(threshold: 0.008, ringingInterval: 0.085, doubleTapInterval: 0.39)
            var preferences = AtmosPreferences(displayTapProfile: profile)
            XCTAssertEqual(preferences.displayTapThreshold, profile.threshold)
            preferences.save(to: defaults)
            XCTAssertEqual(AtmosPreferences.load(from: defaults), preferences)
            preferences.displayTapThreshold = 0.006
            preferences.save(to: defaults)
            XCTAssertEqual(AtmosPreferences.load(from: defaults).displayTapThreshold, 0.006)
            XCTAssertEqual(AtmosPreferences.load(from: defaults).displayTapProfile, profile)
        }
    }

    func testDamagedCalibrationRetainsExistingManualThreshold() {
        withDefaults { defaults in
            defaults.set(0.011, forKey: "atmos.displayTapThreshold")
            for invalid in ["garbled", #"{"threshold":0.02,"ringingInterval":2,"doubleTapInterval":0.2}"#] {
                defaults.set(Data(invalid.utf8), forKey: "atmos.displayTapProfile")
                let loaded = AtmosPreferences.load(from: defaults)
                XCTAssertNil(loaded.displayTapProfile)
                XCTAssertEqual(loaded.displayTapThreshold, 0.011)
            }
        }
    }

    private func withDefaults(_ body: (UserDefaults) -> Void) {
        let suite = "AtmosPreferencesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(defaults)
    }
}
