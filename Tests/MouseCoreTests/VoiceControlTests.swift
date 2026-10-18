import XCTest
@testable import MouseCore

final class VoiceControlTests: XCTestCase {
    func testBareStopIsTheOnlyLocalControl() {
        for text in ["stop", " STOP ", "Stop!", "stop.", "Stop?", "Stop!?"] {
            XCTAssertEqual(VoiceControl.match(text), .sleep, text)
        }
    }

    func testEveryOtherPhraseIsLeftForTheModel() {
        for text in ["", "cancel", "cancel that", "sleep", "go to sleep", "stop listening", "stop now", "stop Mouse", "Mouse stop", "Hey Mouse stop", "please stop", "can you stop", "stop that", "stop the current action", "stop by later", "don't stop", "he said stop", "type stop", "search for stop", "\"stop\"", "‘stop’", "“stop”", "(stop)", "[stop]", "{stop}"] {
            XCTAssertNil(VoiceControl.match(text), text)
        }
    }
}
