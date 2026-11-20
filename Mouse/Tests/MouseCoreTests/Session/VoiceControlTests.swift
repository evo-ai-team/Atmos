import XCTest
@testable import MouseCore

final class VoiceControlTests: XCTestCase {
    func testInitialStopIsTheOnlyLocalControl() {
        for text in ["stop", " STOP ", "Stop!", "stop.", "Stop?", "Stop!?", "stop now", "stop listening", "stop Mouse", "stop that", "stop the current action", "stop by later"] {
            XCTAssertEqual(VoiceControl.match(text), .sleep, text)
        }
    }

    func testEveryOtherPhraseIsLeftForTheModel() {
        for text in ["", "stopping", "stopper", "stopped", "stopwatch", "cancel", "cancel that", "sleep", "go to sleep", "Mouse stop", "Hey Mouse stop", "please stop", "can you stop", "don't stop", "he said stop", "type stop", "search for stop", "\"stop\"", "‘stop’", "“stop”", "(stop)", "[stop]", "{stop}"] {
            XCTAssertNil(VoiceControl.match(text), text)
        }
    }
}
