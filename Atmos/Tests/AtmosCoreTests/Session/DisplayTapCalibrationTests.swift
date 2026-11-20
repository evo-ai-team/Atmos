import XCTest
@testable import AtmosCore

final class DisplayTapCalibrationTests: XCTestCase {
    private typealias Sample = DisplayTapCalibration.Sample

    /// A 100 Hz stream with steady gravity, deterministic low-amplitude jitter
    /// and optional repeatable chassis rebound 140 ms after each finger impact.
    private func capture(_ taps: [Int] = [], strength: Double = 0.009, ring: Bool = true) -> [Sample] {
        let shape = [0.52, 1.0, -0.53, 0.12]
        return (0...200).map { tick in
            var x = 0.003 + sin(Double(tick) * 0.7) * 0.00020
            for tap in taps {
                if shape.indices.contains(tick - tap) { x += shape[tick - tap] * strength }
                if ring, shape.indices.contains(tick - tap - 14) { x += shape[tick - tap - 14] * strength * 0.42 }
            }
            return Sample(time: Double(tick) * 0.01, acceleration: SIMD3(x, 0.004, -1.001))
        }
    }

    private func trained() throws -> (DisplayTapCalibration, DisplayTapProfile) {
        var calibration = DisplayTapCalibration()
        XCTAssertNil(try calibration.evaluate(capture()))
        for i in 1...3 {
            XCTAssertEqual(calibration.step, .single(i))
            XCTAssertNil(try calibration.evaluate(capture([38 + i * 4], strength: 0.007 + 0.001 * Double(i))))
        }
        var result: DisplayTapProfile?
        for (index, gap) in [35, 41, 46].enumerated() {
            XCTAssertEqual(calibration.step, .double(index + 1))
            result = try calibration.evaluate(capture([50, 50 + gap]))
        }
        XCTAssertEqual(calibration.step, .complete)
        return (calibration, try XCTUnwrap(result))
    }

    private func events(_ data: [Sample], detector: inout DisplayTapRecognizer) -> [DisplayTapRecognizer.Event] {
        data.flatMap { detector.sample(x: $0.acceleration.x, y: $0.acceleration.y, z: $0.acceleration.z, at: $0.time) }
    }

    func testLearnsLightTapsRingDurationAndIndividualPairTimingFromRawReports() throws {
        let (_, profile) = try trained()
        XCTAssertTrue(profile.isValid)
        XCTAssertLessThan(profile.threshold, 0.008)
        XCTAssertGreaterThan(profile.ringingInterval, 0.14)
        XCTAssertGreaterThan(profile.doubleTapInterval, 0.46)
        let saved = try JSONEncoder().encode(profile)
        XCTAssertEqual(try JSONDecoder().decode(DisplayTapProfile.self, from: saved), profile)
        var ordinary = DisplayTapRecognizer()
        XCTAssertEqual(events(capture([50, 94]), detector: &ordinary), [])
        var fitted = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(events(capture([50, 94]), detector: &fitted), [.firstTapPending, .doubleTap])
        fitted.reset()
        XCTAssertEqual(events(capture([48]), detector: &fitted), [.firstTapPending, .singleTap])
        var manual = DisplayTapRecognizer(profile: profile, thresholdOverride: 0.080)
        manual.reset()
        XCTAssertEqual(events(capture([50, 94]), detector: &manual), [])
    }

    func testMissingExtraAmbiguousOrClippedGesturesRetrySameTrial() throws {
        var c = DisplayTapCalibration()
        _ = try c.evaluate(capture())
        XCTAssertThrowsError(try c.evaluate(capture())) {
            XCTAssertEqual($0 as? DisplayTapCalibration.Failure, .noTap)
        }
        for invalid in [capture([30, 57]), capture([2]), capture([198])] {
            XCTAssertThrowsError(try c.evaluate(invalid))
            XCTAssertEqual(c.step, .single(1))
        }
        for _ in 0..<3 { _ = try c.evaluate(capture([37])) }
        _ = try c.evaluate(capture([38, 75]))
        XCTAssertEqual(c.step, .double(2))
        for invalid in [capture(), capture([44]), capture([40, 66, 91]), capture([22, 110]),
                        capture([40, 48], ring: false)] {
            XCTAssertThrowsError(try c.evaluate(invalid))
            XCTAssertEqual(c.step, .double(2))
        }
        _ = try c.evaluate(capture([38, 82]))
        XCTAssertNotNil(try c.evaluate(capture([38, 78])))
    }

    func testMissingReportsAndMovingBaselineDoNotAdvance() {
        var c = DisplayTapCalibration()
        let idle = capture()
        let gapped = Array(idle.prefix(30)) + Array(idle.dropFirst(100))
        let shifted = idle.map { Sample(time: $0.time, acceleration: $0.acceleration + SIMD3($0.time * 0.04, 0, 0)) }
        for invalid in [[], Array(idle.prefix(50)), gapped, shifted, capture([58], strength: 0.060)] {
            XCTAssertThrowsError(try c.evaluate(invalid))
            XCTAssertEqual(c.step, .baseline)
        }
    }

    func testBiasedInitialReportAndOngoingJitterAllowSixCuedExamples() throws {
        func window(_ taps: [Int]) -> [Sample] {
            var seed: UInt64 = 97687
            return (0...200).map { i in
                seed = 2862933555777941757 &* seed &+ 3037000493
                let noise = 0.0038 * (Double(seed >> 32) / Double(UInt32.max) - 0.5)
                let t = Double(i) / 100 + (i.isMultiple(of: 3) ? 0 : 0.002)
                var z = -1 + noise + 0.0009 * sin(Double(i) * 1.8)
                if i == 0 { z += 0.008 }
                for index in taps {
                    let dt = t - Double(index) / 100
                    if (0...0.085).contains(dt) { z += 0.026 * exp(-dt / 0.025) * cos(140 * dt) }
                }
                return Sample(time: t, acceleration: SIMD3(0.004 + noise * 0.23, 0.002, z))
            }
        }
        var c = DisplayTapCalibration()
        _ = try c.evaluate(window([]))
        for i in 1...3 { _ = try c.evaluate(window([40 + i])) }
        for gap in [30, 41] { _ = try c.evaluate(window([38, 38 + gap])) }
        let p = try XCTUnwrap(c.evaluate(window([40, 88])))
        var detector = DisplayTapRecognizer(profile: p)
        XCTAssertEqual(events(window([]), detector: &detector), [])
        detector.reset()
        XCTAssertEqual(events(window([43, 78]), detector: &detector), [.firstTapPending, .doubleTap])
    }

    func testFitRejectsProfilesThatWakeOnQuietBaselineOutlier() throws {
        let quietWithOutlier = capture([47], strength: 0.0075, ring: false)
        var c = DisplayTapCalibration()
        _ = try c.evaluate(quietWithOutlier)
        for _ in 1...3 { _ = try c.evaluate(capture([41], strength: 0.015, ring: false)) }
        for _ in 1...2 { _ = try c.evaluate(capture([40, 78], strength: 0.015, ring: false)) }
        let p = try XCTUnwrap(c.evaluate(capture([48, 86], strength: 0.015, ring: false)))
        var detector = DisplayTapRecognizer(profile: p)
        XCTAssertEqual(events(quietWithOutlier, detector: &detector), [])
    }

    func testDoubleTrialsIgnoreSubTapVibrationAndRejectAnExtraFullImpact() throws {
        var c = DisplayTapCalibration()
        _ = try c.evaluate(capture())
        for _ in 1...3 { _ = try c.evaluate(capture([40], strength: 0.030, ring: false)) }
        let quiet = capture()
        let pair = capture([40, 74], strength: 0.030, ring: false)
        func withDistractor(strength: Double) -> [Sample] {
            let bump = capture([146], strength: strength, ring: false)
            return pair.indices.map { i in
                Sample(time: pair[i].time, acceleration: pair[i].acceleration + (bump[i].acceleration - quiet[i].acceleration))
            }
        }
        XCTAssertNil(try c.evaluate(withDistractor(strength: 0.012)))
        XCTAssertEqual(c.step, .double(2))
        XCTAssertThrowsError(try c.evaluate(withDistractor(strength: 0.029)))
        XCTAssertEqual(c.step, .double(2))
    }

    func testRedoSinglesAndDoublesRetainsOtherConsistentExamples() throws {
        let (initial, original) = try trained()
        var c = initial
        c.redoSingles()
        for i in 1...3 {
            XCTAssertEqual(c.step, .single(i))
            let value = try c.evaluate(capture([38 + i], strength: 0.008))
            XCTAssertEqual(value != nil, i == 3)
        }
        XCTAssertEqual(c.step, .complete)
        c.redoDoubles()
        for gap in [24, 25] { XCTAssertNil(try c.evaluate(capture([40, 40 + gap]))) }
        let refitted = try XCTUnwrap(c.evaluate(capture([40, 66])))
        XCTAssertEqual(c.step, .complete)
        XCTAssertLessThan(refitted.doubleTapInterval, original.doubleTapInterval)
    }

    func testRedoRejectsIncompatibleSingleBeforeChangingSavedPairs() throws {
        var c = DisplayTapCalibration()
        _ = try c.evaluate(capture())
        for _ in 1...3 { _ = try c.evaluate(capture([40], ring: false)) }
        for _ in 1...3 { _ = try c.evaluate(capture([40, 56], ring: false)) }
        XCTAssertEqual(c.step, .complete)
        c.redoSingles()
        XCTAssertThrowsError(try c.evaluate(capture([40], ring: true))) {
            XCTAssertEqual($0 as? DisplayTapCalibration.Failure, .incompatibleSingle)
        }
        XCTAssertEqual(c.step, .single(1))
        for _ in 0..<2 { XCTAssertNil(try c.evaluate(capture([45], ring: false))) }
        XCTAssertNotNil(try c.evaluate(capture([48], ring: false)))
        XCTAssertEqual(c.step, .complete)
    }

    func testInvalidStoredProfileCannotOverrideRuntimeTiming() {
        let invalid = DisplayTapProfile(threshold: 0.004, ringingInterval: 0.31, doubleTapInterval: 0.16)
        XCTAssertFalse(invalid.isValid)
        var detector = DisplayTapRecognizer(profile: invalid)
        XCTAssertEqual(detector.threshold, DisplayTapRecognizer.defaultThreshold)
        XCTAssertEqual(events(capture([40], strength: 0.04, ring: false), detector: &detector), [.firstTapPending, .singleTap])
    }
}
