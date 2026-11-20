import XCTest
@testable import AtmosCore

final class IsolatedSpeechEndpointTests: XCTestCase {
    func testWaitingForInFlightAudioUsesFixedCaptureBoundary() {
        var endpoint = IsolatedSpeechEndpoint()
        XCTAssertFalse(endpoint.ready(cleanThrough: 10.49, capturedThrough: 10.79, lastActivity: 10, silence: 0.5))
        XCTAssertFalse(endpoint.ready(cleanThrough: 10.5, capturedThrough: 10.8, lastActivity: 10, silence: 0.5))
        XCTAssertFalse(endpoint.ready(cleanThrough: 10.79, capturedThrough: 11.1, lastActivity: 10, silence: 0.5))
        XCTAssertTrue(endpoint.ready(cleanThrough: 10.8, capturedThrough: 11.11, lastActivity: 10, silence: 0.5))
    }

    func testBufferedContinuationStartsANewSilenceWindow() {
        var endpoint = IsolatedSpeechEndpoint()
        XCTAssertFalse(endpoint.ready(cleanThrough: 10.5, capturedThrough: 10.8, lastActivity: 10, silence: 0.5))
        XCTAssertFalse(endpoint.ready(cleanThrough: 10.8, capturedThrough: 11.1, lastActivity: 10.6, silence: 0.5))
        XCTAssertFalse(endpoint.ready(cleanThrough: 11.2, capturedThrough: 11.5, lastActivity: 10.6, silence: 0.5))
        XCTAssertTrue(endpoint.ready(cleanThrough: 11.5, capturedThrough: 11.8, lastActivity: 10.6, silence: 0.5))
    }
}
