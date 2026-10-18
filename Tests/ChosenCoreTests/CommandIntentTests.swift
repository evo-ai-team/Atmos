import XCTest
@testable import ChosenCore

final class CommandIntentTests: XCTestCase {
    func testClearComputerCommandsAndPoliteRequestsAreAccepted() {
        let commands = [
            "Open Chrome", "Open up YouTube", "Go to Chrome", "Can you open Chrome?", "Could you please open Safari?",
            "Please search YouTube", "search for Linus Tech Tips", "go fullscreen", "exit full screen", "scroll down",
            "scroll down two pages", "click that", "click on the Mr Beast video", "click his store link", "go to his profile",
            "Go to Chrome, open up YouTube and then go search Linus Tech Tips, go to his channel, and click on his store link in his profile",
            "go to Chrome open up YouTube and then go search Linus Tech Tips go to his channel and click on his store link in his profile",
            "open Chrome and search for cats", "open Chrome then", "press command shift t", "hit Enter", "type hello world",
            "close the current tab", "new tab", "next tab", "go back", "reload the page", "copy selected text", "paste", "select all",
            "go search YouTube", "now search for cats", "play the video", "pause the video", "scroll to comments", "open Unknown Imaginary App", "open https://example.com", "open youtube.com", "open /Applications/Safari.app", "switch to Google Chrome"
        ]
        for text in commands { XCTAssertTrue(CommandIntent.isClearCommand(text), text) }
    }

    func testConversationQuestionsReportedSpeechAndNegationAreIgnored() {
        let utterances = [
            "", "hello", "thanks", "that's nice", "what is the weather", "how do I open Chrome", "why did you click that",
            "Can you explain Chrome?", "can you tell me how to open Chrome", "he said open Chrome", "I was told to search YouTube",
            "don't open Chrome", "please do not open Chrome", "can you not open Chrome", "never open Chrome", "if you open Chrome",
            "when I open Chrome it crashes", "open-minded people", "open minded people", "open Chrome is what he asked",
            "search is important", "click with people", "type of computer", "select an outfit", "go to dinner", "stop by later",
            "Search results are awful", "Search engines are getting worse", "Click bait is everywhere", "Type two diabetes is common", "Search uh um", "Click um", "Can you type faster than me?", "Open the window tomorrow", "can you help with dinner", "open Unknown Imaginary Thing", "\"open Chrome\"", "‘open Chrome’"
        ]
        for text in utterances { XCTAssertFalse(CommandIntent.isClearCommand(text), text) }
    }

    func testIncompleteCommandsAreNotAdmitted() {
        for text in ["open", "go", "go to", "search", "search for", "click", "click on", "type", "press", "scroll", "scroll through", "switch to", "right click"] {
            XCTAssertFalse(CommandIntent.isClearCommand(text), text)
        }
    }

    func testTypedAndSearchedPayloadsDoNotBecomeControlsOrQuestions() {
        for text in ["type stop listening", "type why did you stop", "type don't open Chrome", "search for stop listening", "search why did you stop", "search for how do I open Chrome", "search for cancel my reservation", "type hello and then goodbye", "type a", "type \"hello is good\"", "Type \"hello is good\""] {
            XCTAssertNil(CommandIntent.control(text), text)
            XCTAssertTrue(CommandIntent.isClearCommand(text), text)
        }
    }

    func testExactControlsAreSeparateFromComputerCommands() {
        for text in ["stop", "cancel", "cancel that", "Mouse stop", "Hey Mouse stop", "please stop", "stop Mouse", "can you stop", "stop the current action"] {
            XCTAssertEqual(CommandIntent.control(text), .stop, text)
            XCTAssertFalse(CommandIntent.isClearCommand(text), text)
        }
        for text in ["stop listening", "go to sleep", "sleep Mouse", "sleep Chosen", "please stop listening", "Mouse go to sleep", "stop listening please"] {
            XCTAssertEqual(CommandIntent.control(text), .sleep, text)
            XCTAssertFalse(CommandIntent.isClearCommand(text), text)
        }
    }

    func testControlWordsInsideConversationDoNotTrigger() {
        for text in ["stop by later", "don't stop", "cancel my dinner reservation", "stop listening to that story", "he said stop", "we should go to sleep soon", "go to sleep after dinner", "\"stop\"", "please don't stop", "type stop", "search for go to sleep"] {
            XCTAssertNil(CommandIntent.control(text), text)
        }
    }
}
