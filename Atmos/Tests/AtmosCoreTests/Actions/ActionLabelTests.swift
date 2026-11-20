import XCTest
@testable import AtmosCore

final class ActionLabelTests: XCTestCase {
    func testKeepsShortActionAndTargetLabels() {
        for label in ["Loading Store", "Opening YouTube", "Clicking Channel", "Reviewing"] {
            XCTAssertEqual(ActionLabel.compact(label), label)
        }
    }

    func testLongDescriptionsKeepTheTargetInsteadOfAnArticle() {
        XCTAssertEqual(ActionLabel.compact("Click the Home button to return to the main page"), "Click Home")
        XCTAssertEqual(ActionLabel.compact("Opening a menu to inspect the available options"), "Opening menu")
        XCTAssertEqual(ActionLabel.compact("Clicking an account"), "Clicking account")
    }

    func testNativeLabelsLoseTheirEllipsisAndExtraWords() {
        XCTAssertEqual(ActionLabel.compact("Clicking Home…"), "Clicking Home")
        XCTAssertEqual(ActionLabel.compact("Opening Channel context menu…"), "Opening Channel")
        XCTAssertEqual(ActionLabel.compact("Increasing slider..."), "Increasing slider")
        XCTAssertEqual(ActionLabel.compact("Decreasing slider....."), "Decreasing slider")
    }

    func testWhitespaceAndPunctuationDoNotConsumeTheWordBudget() {
        XCTAssertEqual(ActionLabel.compact("  Loading\n\tStore\r\ncontents  "), "Loading Store")
        XCTAssertEqual(ActionLabel.compact("Clicking\u{0000}Home"), "Clicking Home")
        XCTAssertEqual(ActionLabel.compact("Opening … YouTube"), "Opening YouTube")
        XCTAssertEqual(ActionLabel.compact("Click the “Home” button"), "Click Home")
    }

    func testMissingOrUnboundedLabelsUseReadableFallbacks() {
        for label in ["", " \n\t", "… ...", String(repeating: "w", count: 200)] {
            XCTAssertEqual(ActionLabel.compact(label), "Working")
        }
        XCTAssertEqual(ActionLabel.compact("Opening \(String(repeating: "w", count: 200))"), "Opening")
        XCTAssertEqual(ActionLabel.compact("Click the"), "Click")
    }
}
