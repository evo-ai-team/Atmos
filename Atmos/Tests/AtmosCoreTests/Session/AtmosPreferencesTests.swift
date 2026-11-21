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
            XCTAssertFalse(AtmosPreferences.load(from: defaults).displayTapsEnabled)
        }
    }

    func testAllModesAndAudioChoicesSurviveReload() {
        withDefaults { defaults in
            for behavior in ChatbotBehavior.allCases {
                let preferences = AtmosPreferences(behavior: behavior, audioSensitivity: 0.8, secondPassEnabled: false,
                                                   vivaProEnabled: true, displayTapsEnabled: false,
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

    func testSavedCalibrationAndDisabledChoiceSurviveRelaunch() {
        withDefaults { defaults in
            let profile = DisplayTapProfile(threshold: 0.015, maximumPeak: 0.095, axis: SIMD3(0, 0, 1),
                                            ringingInterval: 0.115, doubleTapInterval: 0.4)
            var preferences = AtmosPreferences(displayTapsEnabled: true, displayTapProfile: profile)
            preferences.save(to: defaults)
            XCTAssertEqual(AtmosPreferences.load(from: defaults), preferences)
            preferences.displayTapsEnabled = false
            preferences.save(to: defaults)
            XCTAssertEqual(AtmosPreferences.load(from: defaults), preferences)
        }
    }

    func testLegacyEnabledAndCalibratedInstallationsRemainOffUntilNewCalibration() {
        withDefaults { defaults in
            defaults.set(true, forKey: "atmos.displayTapsEnabled")
            defaults.set(0.001, forKey: "atmos.displayTapThreshold")
            XCTAssertFalse(AtmosPreferences.load(from: defaults).displayTapsEnabled)
            for invalid in ["garbled", #"{"threshold":0.002,"ringingInterval":0.11,"doubleTapInterval":0.3}"#,
                            #"{"version":1,"threshold":0.02,"maximumPeak":0.09,"axis":[1,0,0],"ringingInterval":0.11,"doubleTapInterval":0.3}"#] {
                defaults.set(Data(invalid.utf8), forKey: "atmos.displayTapProfile")
                let loaded = AtmosPreferences.load(from: defaults)
                XCTAssertNil(loaded.displayTapProfile)
                XCTAssertFalse(loaded.displayTapsEnabled)
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
