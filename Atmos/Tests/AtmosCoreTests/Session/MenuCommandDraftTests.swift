import XCTest
@testable import AtmosCore

final class MenuCommandDraftTests: XCTestCase {
    func testAlternativesAndFinalReplaceOneSpanAcrossMultipleUtterances() {
        var draft = MenuCommandDraft()
        draft.edit("Please")
        draft.preview("ope")
        draft.preview("open maps")
        draft.finalize("open Maps")
        draft.preview("")
        draft.preview("and zoo")
        draft.finalize("and zoom")
        XCTAssertEqual(draft.take(), "Please open Maps and zoom")
        XCTAssertNil(draft.take())
    }

    func testEditsBesideLiveWordsAreRetainedOnReplay() {
        var draft = MenuCommandDraft()
        draft.edit("find")
        draft.preview("a park")
        XCTAssertFalse(draft.edit("find a park near me"))
        XCTAssertFalse(draft.edit("locate a park near me"))
        draft.finalize("the park")
        XCTAssertEqual(draft.text, "locate the park near me")
    }

    func testUserCanEditWhitespaceAtInsertionBoundary() {
        var draft = MenuCommandDraft()
        draft.edit("prefix")
        draft.preview("words")
        XCTAssertFalse(draft.edit("prefixwords"))
        draft.finalize("revised")
        XCTAssertEqual(draft.text, "prefixrevised")
    }

    func testOverwritingLiveWordsRequestsANewAudioBoundary() {
        var draft = MenuCommandDraft()
        draft.preview("change park")
        XCTAssertTrue(draft.edit("change dark"))
        draft.preview("")
        draft.finalize("mode")
        XCTAssertEqual(draft.text, "change dark mode")
    }

    func testStopOrNavigateFreezesPreviewAndManualSendConsumesItOnce() {
        var draft = MenuCommandDraft()
        draft.edit("type")
        draft.preview("Hey Atmos stop")
        draft.endDictation()
        draft.preview("")
        XCTAssertEqual(draft.text, "type Hey Atmos stop")
        draft.preview("please")
        XCTAssertEqual(draft.take(), "type Hey Atmos stop please")
        draft.endDictation()
        XCTAssertNil(draft.take())
        draft.edit("  \n ")
        XCTAssertNil(draft.take())
    }
}
