import XCTest
@testable import AtmosCore

final class DisplayTapRecognizerTests: XCTestCase {
    private let profile = DisplayTapProfile(threshold: 0.015, maximumPeak: 0.12, axis: SIMD3(1, 0, 0),
                                            ringingInterval: 0.115, doubleTapInterval: 0.30)

    // One sample per 10 ms. A short rise, reversal, and decay are superimposed
    // on gravity in an arbitrary orientation.
    private func feed(_ ticks: ClosedRange<Int>, into detector: inout DisplayTapRecognizer,
                      taps: [Int] = [], shouldAcceptImpulse: (TimeInterval) -> Bool = { _ in true },
                      disturbance: (Int) -> Double = { _ in 0 }) -> [DisplayTapRecognizer.Event] {
        let shape = [0.010, 0.030, -0.016, 0.005]
        var events = [DisplayTapRecognizer.Event]()
        for i in ticks {
            var impact = disturbance(i)
            for start in taps where shape.indices.contains(i - start) { impact += shape[i - start] }
            events += detector.sample(x: 0.8 + impact, y: -0.55, z: 0.2, at: Double(i) / 100,
                                      shouldAcceptImpulse: shouldAcceptImpulse)
        }
        return events
    }

    func testSingleTapWaitsForPairingWindowAndIgnoresRinging() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...45, into: &detector, taps: [20, 28]), [.firstTapPending])
        XCTAssertNotNil(detector.pendingDeadline)
        XCTAssertEqual(feed(46...90, into: &detector), [.singleTap])
        XCTAssertNil(detector.pendingDeadline)
        XCTAssertEqual(detector.advance(to: 10), [])
    }

    func testSecondTapNearDeadlineConfirmsOnlyDoubleEvenWhenReportsAreBatched() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...44, into: &detector, taps: [20]), [.firstTapPending])
        // The main loop has reached 530 ms, but reports through the 510 ms
        // deadline have not arrived. The actual second pulse began at 500 ms.
        XCTAssertEqual(detector.advance(to: 0.53), [])
        XCTAssertEqual(feed(45...52, into: &detector, taps: [49]), [])
        XCTAssertEqual(detector.advance(to: 0.60), [])
        XCTAssertEqual(feed(53...95, into: &detector, taps: [49, 69]), [.doubleTap])
        XCTAssertNil(detector.pendingDeadline)
    }

    func testTwoWidelySpacedTapsProduceTwoSingles() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...110, into: &detector, taps: [20, 57]),
                       [.firstTapPending, .singleTap, .firstTapPending, .singleTap])
    }

    func testKeyboardVibrationBeforeRealTapDoesNotBecomeADouble() {
        var detector = DisplayTapRecognizer(profile: profile)
        var onsets = Set<TimeInterval>()
        let events = feed(0...100, into: &detector, taps: [20, 42], shouldAcceptImpulse: { onset in
            onsets.insert(onset)
            return onset > 0.3
        })
        XCTAssertEqual(onsets.sorted(), [0.21, 0.43])
        XCTAssertEqual(events, [.firstTapPending, .singleTap])
    }

    func testKeyboardVibrationNearDeadlineKeepsFirstSingleTap() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...48, into: &detector, taps: [20]), [.firstTapPending])
        let events = feed(49...90, into: &detector, taps: [49], shouldAcceptImpulse: { onset in
            XCTAssertEqual(onset, 0.50, accuracy: 0.000_001)
            return false
        })
        XCTAssertEqual(events, [.singleTap])
        XCTAssertNil(detector.pendingDeadline)
    }

    func testClickArrivingAfterSettlingVetoesAnOtherwiseValidSingle() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...78, into: &detector, taps: [70]), [])
        // The click arrives 80 ms after the impulse's onset at 710 ms. By now
        // the mechanical pulse has settled, but it cannot be classified yet.
        let events = feed(79...150, into: &detector, shouldAcceptImpulse: { onset in
            XCTAssertEqual(onset, 0.71, accuracy: 0.000_001)
            return false
        })
        XCTAssertEqual(events, [])
    }

    func testLateClickDuringSecondImpulsesVetoWindowPreservesTheFirstSingle() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...57, into: &detector, taps: [20, 49]), [.firstTapPending])
        // Near-deadline second tap at 500 ms, followed by a click at 580 ms.
        // The real first tap must still resolve once, with no menu opening.
        let events = feed(58...110, into: &detector, shouldAcceptImpulse: { onset in
            XCTAssertEqual(onset, 0.50, accuracy: 0.000_001)
            return false
        })
        XCTAssertEqual(events, [.singleTap])
    }

    func testCleanSecondImpulseAtPairDeadlineWaitsForFullInputWindow() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...61, into: &detector, taps: [20, 49]), [.firstTapPending])
        XCTAssertEqual(detector.advance(to: 3), [])
        XCTAssertEqual(feed(62...100, into: &detector), [.doubleTap])
    }

    func testSustainedVibrationSlowLidMovementAndFaintKeypressesStayQuiet() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...170, into: &detector, disturbance: { i in
            (20...95).contains(i) ? (i.isMultiple(of: 2) ? 0.035 : -0.035) : 0
        }), [])
        detector.reset()
        XCTAssertEqual(feed(0...200, into: &detector, disturbance: { i in min(0.4, max(0, Double(i - 20) * 0.003)) }), [])
        detector.reset()
        XCTAssertEqual(feed(0...200, into: &detector, disturbance: { $0.isMultiple(of: 9) ? 0.006 : 0 }), [])
        detector.reset()
        XCTAssertEqual(feed(0...150, into: &detector, disturbance: { $0 >= 25 ? 0.065 : 0 }), [])
    }

    func testResetOrSampleOutageDiscardsAnUnresolvedAction() {
        var detector = DisplayTapRecognizer(profile: profile)
        XCTAssertEqual(feed(0...35, into: &detector, taps: [20]), [.firstTapPending])
        detector.reset()
        XCTAssertNil(detector.pendingDeadline)
        XCTAssertEqual(feed(36...65, into: &detector), [])
        XCTAssertEqual(feed(66...86, into: &detector, taps: [70]), [.firstTapPending])
        XCTAssertEqual(feed(130...185, into: &detector), [])
        XCTAssertNil(detector.pendingDeadline)
    }

    func testThresholdAppliesToAllThreeAxesAndOutOfOrderSamplesCannotFire() {
        let vertical = DisplayTapProfile(threshold: 0.008, maximumPeak: 0.10, axis: SIMD3(0, 0, 1),
                                         ringingInterval: 0.115, doubleTapInterval: 0.30)
        var detector = DisplayTapRecognizer(profile: vertical)
        var events = [DisplayTapRecognizer.Event]()
        for i in 0...90 {
            let z = i == 20 ? -0.988 : i == 21 ? -1.007 : -1.0
            events += detector.sample(x: 0.002, y: 0.004, z: z, at: Double(i) / 100)
            events += detector.sample(x: 0, y: 0, z: 7, at: Double(i) / 100 - 0.005)
        }
        XCTAssertEqual(events, [.firstTapPending, .singleTap])
    }
}
