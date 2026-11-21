import XCTest
@testable import AtmosCore

final class DisplayTapCalibrationTests: XCTestCase {
    private typealias Sample = DisplayTapCalibration.Sample

    /// A 100 Hz stream with steady gravity, deterministic low-amplitude jitter
    /// and optional repeatable chassis rebound 140 ms after each finger impact.
    private func capture(_ taps: [Int] = [], strength: Double = 0.025, ring: Bool = true) -> [Sample] {
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

    private func fitted() throws -> (DisplayTapCalibration, DisplayTapProfile) {
        var c = DisplayTapCalibration()
        XCTAssertEqual(c.step, .single)
        XCTAssertNil(try c.evaluate(capture([44]), baseline: capture(), cueAt: 0.10))
        XCTAssertEqual(c.step, .double)
        let profile = try XCTUnwrap(c.evaluate(capture([43, 82]), baseline: capture(), cueAt: 0.10))
        XCTAssertEqual(c.step, .complete)
        return (c, profile)
    }

    private func events(_ samples: [Sample], profile: DisplayTapProfile) -> [DisplayTapRecognizer.Event] {
        var detector = DisplayTapRecognizer(profile: profile)
        return samples.flatMap { detector.sample(x: $0.acceleration.x, y: $0.acceleration.y, z: $0.acceleration.z, at: $0.time) }
    }

    func testTwoRecordingsLearnStrengthDirectionRingingAndPace() throws {
        let (_, p) = try fitted()
        XCTAssertTrue(p.isValid)
        XCTAssertGreaterThan(p.threshold, 0.017)
        XCTAssertGreaterThan(p.ringingInterval, 0.14)
        XCTAssertGreaterThan(p.doubleTapInterval, 0.39)
        let encoded = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(DisplayTapProfile.self, from: encoded), p)
        XCTAssertEqual(events(capture([46]), profile: p), [.firstTapPending, .singleTap])
        XCTAssertEqual(events(capture([47, 86]), profile: p), [.firstTapPending, .doubleTap])
    }

    func testFaintBumpsOffAxisMotionOneFrameSpikesAndStrongKnocksDoNotActivate() throws {
        let (_, p) = try fitted()
        let offAxis = capture([40]).map { Sample(time: $0.time, acceleration: SIMD3($0.acceleration.y, $0.acceleration.x, -1)) }
        let spike = capture().map { Sample(time: $0.time, acceleration: $0.acceleration + SIMD3($0.time == 0.4 ? 0.035 : 0, 0, 0)) }
        for disturbance in [capture(), capture([41, 76], strength: 0.012), offAxis, spike, capture([40], strength: 0.11, ring: false)] {
            XCTAssertEqual(events(disturbance, profile: p), [])
        }
    }

    func testMissingExtraAndClippedImpactsDoNotAdvanceSingle() throws {
        var c = DisplayTapCalibration()
        for invalid in [capture(), capture([30, 59]), capture([2]), capture([198]), capture([40], strength: 0.004)] {
            XCTAssertThrowsError(try c.evaluate(invalid, baseline: capture(), cueAt: 0.10))
            XCTAssertEqual(c.step, .single)
        }
        XCTAssertNil(try c.evaluate(capture([45]), baseline: capture(), cueAt: 0.10))
    }

    func testMissingOrAmbiguousSecondTapCanBeRetriedWithoutRepeatingSingle() throws {
        var c = DisplayTapCalibration()
        _ = try c.evaluate(capture([46]), baseline: capture(), cueAt: 0.10)
        for invalid in [capture(), capture([44]), capture([40, 66, 91]), capture([22, 110]), capture([40, 48], ring: false),
                        capture([44, 77], strength: 0.010)] {
            XCTAssertThrowsError(try c.evaluate(invalid, baseline: capture(), cueAt: 0.10))
            XCTAssertEqual(c.step, .double)
        }
        XCTAssertNotNil(try c.evaluate(capture([40, 72]), baseline: capture(), cueAt: 0.10))
    }

    func testMissingReportsAndMovingBaselineDoNotAdvance() {
        let idle = capture()
        let gap = Array(idle.prefix(30)) + Array(idle.dropFirst(100))
        let drift = idle.map { Sample(time: $0.time, acceleration: $0.acceleration + SIMD3($0.time * 0.04, 0, 0)) }
        for invalid in [[], Array(idle.prefix(9)), gap, drift, capture([58], strength: 0.060)] {
            var c = DisplayTapCalibration()
            XCTAssertThrowsError(try c.evaluate(capture([40]), baseline: invalid, cueAt: 0.10))
            XCTAssertEqual(c.step, .single)
        }
    }

    func testDoublesIgnoreSubTapVibrationAndRejectAnExtraFullImpact() throws {
        var c = DisplayTapCalibration()
        _ = try c.evaluate(capture([40], strength: 0.030, ring: false), baseline: capture(), cueAt: 0.10)
        let quiet = capture()
        let pair = capture([40, 74], strength: 0.030, ring: false)
        func withDistractor(strength: Double) -> [Sample] {
            let bump = capture([146], strength: strength, ring: false)
            return pair.indices.map { i in
                Sample(time: pair[i].time, acceleration: pair[i].acceleration + (bump[i].acceleration - quiet[i].acceleration))
            }
        }
        XCTAssertThrowsError(try c.evaluate(withDistractor(strength: 0.029), baseline: quiet, cueAt: 0.10))
        XCTAssertNotNil(try c.evaluate(withDistractor(strength: 0.012), baseline: quiet, cueAt: 0.10))
    }

    func testReRecordDoubleRetainsSingleAndReRecordSingleStartsNewFit() throws {
        var (c, original) = try fitted()
        c.redoDouble()
        XCTAssertEqual(c.step, .double)
        let faster = try XCTUnwrap(c.evaluate(capture([40, 65]), baseline: capture(), cueAt: 0.10))
        XCTAssertLessThan(faster.doubleTapInterval, original.doubleTapInterval)
        c.redoSingle()
        XCTAssertEqual(c.step, .single)
        XCTAssertNil(try c.evaluate(capture([42]), baseline: capture(), cueAt: 0.10))
        XCTAssertEqual(c.step, .double)
    }

    func testUnevenSampleTimingAndBiasedFirstReportCanStillCalibrate() throws {
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
        _ = try c.evaluate(window([42]), baseline: window([]), cueAt: 0.10)
        let profile = try XCTUnwrap(c.evaluate(window([40, 82]), baseline: window([]), cueAt: 0.10))
        XCTAssertEqual(events(window([]), profile: profile), [])
        XCTAssertEqual(events(window([43, 78]), profile: profile), [.firstTapPending, .doubleTap])
    }

    func testIsolatedBackgroundBumpCannotTrainTheDetectorToTriggerOnIdle() throws {
        let ambient = capture([47], strength: 0.0075, ring: false)
        var c = DisplayTapCalibration()
        _ = try c.evaluate(capture([41], strength: 0.016, ring: false), baseline: ambient, cueAt: 0.10)
        let profile = try XCTUnwrap(c.evaluate(capture([48, 86], strength: 0.016, ring: false), baseline: ambient, cueAt: 0.10))
        XCTAssertEqual(events(ambient, profile: profile), [])
    }

    func testTapInQuietLeadInCannotStandInForAResponseToThePrompt() throws {
        var c = DisplayTapCalibration()
        let earlySingle = capture([45], strength: 0.010, ring: false)
        let baseline = Array(earlySingle.prefix(49))
        XCTAssertThrowsError(try c.evaluate(earlySingle, baseline: baseline, cueAt: 0.49)) {
            XCTAssertEqual($0 as? DisplayTapCalibration.Failure, .beforeCue)
        }
        XCTAssertEqual(c.step, .single)
        // The final baseline report can have exactly the same clock reading
        // as the cue it triggers. It still arrived before the prompt.
        let edge = capture().enumerated().map { i, sample in
            let bump = i == 50 ? 0.0038 : i == 51 ? 0.010 : 0
            return Sample(time: sample.time, acceleration: sample.acceleration + SIMD3(bump, 0, 0))
        }
        XCTAssertThrowsError(try c.evaluate(edge, baseline: Array(edge.prefix(52)), cueAt: edge[51].time)) {
            XCTAssertEqual($0 as? DisplayTapCalibration.Failure, .beforeCue)
        }
        _ = try c.evaluate(capture([45], ring: false), baseline: capture(), cueAt: 0.10)
        XCTAssertThrowsError(try c.evaluate(capture([41, 78], ring: false), baseline: capture(), cueAt: 0.43)) {
            XCTAssertEqual($0 as? DisplayTapCalibration.Failure, .beforeCue)
        }
        XCTAssertEqual(c.step, .double)
    }

    func testInvalidProfileNeverRecognizesGestures() {
        let invalid = DisplayTapProfile(threshold: 0.0001, maximumPeak: 0.09, axis: SIMD3(1, 0, 0),
                                        ringingInterval: 0.1, doubleTapInterval: 0.32)
        XCTAssertFalse(invalid.isValid)
        XCTAssertEqual(events(capture([45]), profile: invalid), [])
    }
}
