import Foundation
import XCTest
@testable import MouseCore

final class ComputerDecisionTests: XCTestCase {
    func testNativeChoicesResolveToExactElementAndSupportedOperation() throws {
        let element = control(id: "button", label: "Full screen", actions: ["AXPress", "AXShowMenu", "AXIncrement", "AXDecrement", "AXRaise"])
        let options = options([element])
        let natives = nativeChoices(options)
        XCTAssertEqual(natives.count, 4)
        for action in ["AXPress", "AXShowMenu", "AXIncrement", "AXDecrement"] {
            let decision = try options.resolve(result("ax:button:\(action)", for: options))
            guard case .native(let selected, let selectedAction, let description) = decision else {
                return XCTFail("Expected a native choice")
            }
            XCTAssertEqual(selected, element)
            XCTAssertEqual(selectedAction, action)
            XCTAssertFalse(description.isEmpty)
            XCTAssertLessThanOrEqual(description.count, 64)
        }
        XCTAssertFalse(natives.contains { $0.value.contains("AXRaise") })
    }

    func testExcludesDisabledUnknownEnabledSecureAndOffscreenControls() {
        let visible = control(id: "visible")
        var disabled = control(id: "disabled"); disabled.enabled = false
        var unknown = control(id: "unknown"); unknown.enabled = nil
        var secure = control(id: "secure"); secure.secure = true
        var offscreen = control(id: "offscreen"); offscreen.screenshotBounds = nil
        var emptyID = control(id: "")
        emptyID.actions = ["AXPress"]
        let options = options([visible, disabled, unknown, secure, offscreen, emptyID])
        XCTAssertEqual(nativeChoices(options).map(\.value), ["ax:visible:AXPress"])
    }

    func testRejectsInvalidVisibleBounds() {
        let invalidBounds = [
            AccessibilityBounds(x: -1, y: 2, width: 10, height: 10),
            AccessibilityBounds(x: 1, y: -2, width: 10, height: 10),
            AccessibilityBounds(x: 1, y: 2, width: 0, height: 10),
            AccessibilityBounds(x: 1, y: 2, width: 10, height: -10),
            AccessibilityBounds(x: .infinity, y: 2, width: 10, height: 10),
            AccessibilityBounds(x: 1, y: .nan, width: 10, height: 10),
            AccessibilityBounds(x: Double.greatestFiniteMagnitude, y: 2, width: Double.greatestFiniteMagnitude, height: 10)
        ]
        let elements = invalidBounds.enumerated().map { index, bounds in
            var element = control(id: "invalid\(index)"); element.screenshotBounds = bounds
            return element
        }
        XCTAssertTrue(nativeChoices(options(elements)).isEmpty)
    }

    func testNeverOffersDuplicateIDsOrUnsupportedActions() {
        let duplicateA = control(id: "duplicate", label: "Delete")
        let duplicateB = control(id: "duplicate", label: "Save")
        let unsupported = control(id: "unsupported", actions: ["AXRaise", "AXSetValue", "AXConfirm", "press", "type"])
        let repeated = control(id: "repeated", actions: ["AXPress", "AXPress", "AXPress"])
        let choices = nativeChoices(options([duplicateA, duplicateB, unsupported, repeated]))
        XCTAssertEqual(choices.map(\.value), ["ax:repeated:AXPress"])
    }

    func testCapsConcreteChoicesAndPreservesEveryFallback() {
        let elements = (0..<300).map { control(id: String(format: "button_%03d", $0)) }
        let options = options(elements)
        let choices = options.questions[0].choices
        XCTAssertEqual(nativeChoices(options).count, 249)
        XCTAssertEqual(choices.count, 253)
        XCTAssertLessThanOrEqual(choices.count, 255)
        XCTAssertEqual(Set(choices.suffix(4).map(\.value)), ["generate", "complete", "ignore", "review"])
        XCTAssertEqual(Set(choices.map(\.value)).count, choices.count)
    }

    func testMappingsStayStableWhenTreeOrderChangesButRejectAnOlderSnapshot() throws {
        let snapshotID = UUID()
        let a = control(id: "a", actions: ["AXIncrement", "AXPress"])
        let b = control(id: "b", actions: ["AXShowMenu"])
        let first = ComputerDecisionOptions(snapshot: AccessibilitySnapshot(id: snapshotID, processID: 7, elements: [a, b]), allowNativeActions: true, allowCompletion: true)
        let reordered = ComputerDecisionOptions(snapshot: AccessibilitySnapshot(id: snapshotID, processID: 7, elements: [b, a]), allowNativeActions: true, allowCompletion: true)
        XCTAssertEqual(first.questions, reordered.questions)
        let selected = result("ax:a:AXIncrement", for: first)
        XCTAssertEqual(try first.resolve(selected), try reordered.resolve(selected))

        let nextObservation = options([a, b])
        XCTAssertThrowsError(try nextObservation.resolve(selected))
        XCTAssertThrowsError(try nextObservation.resolve(result("complete", for: first)))
    }

    func testTaskAmendmentCanForcePlannerWithoutLosingIgnoreOrReview() throws {
        let snapshot = AccessibilitySnapshot(processID: 7, elements: [control(id: "a")])
        let options = ComputerDecisionOptions(snapshot: snapshot, allowNativeActions: false, allowCompletion: false)
        XCTAssertEqual(options.questions[0].choices.map(\.value), ["generate", "ignore", "review"])
        XCTAssertEqual(try options.resolve(result("generate", for: options)), .generate)
        XCTAssertEqual(try options.resolve(result("review", for: options)), .review)
        XCTAssertEqual(try options.resolve(result("ignore", for: options)), .ignore)
        XCTAssertThrowsError(try options.resolve(result("complete", for: options)))
        XCTAssertThrowsError(try options.resolve(result("ax:a:AXPress", for: options)))
    }

    func testUnavailableTreeCannotOfferStaleElementsButCompletionRemainsExplicitChoice() throws {
        let snapshot = AccessibilitySnapshot(processID: 7, elements: [control(id: "old")], unavailableReason: "App did not respond")
        let options = ComputerDecisionOptions(snapshot: snapshot, allowNativeActions: true, allowCompletion: true)
        XCTAssertTrue(nativeChoices(options).isEmpty)
        XCTAssertEqual(try options.resolve(result("complete", for: options)), .complete)
        // An empty tree alone cannot force completion; the image-based selector
        // still has generate and must inspect the current screenshot.
        XCTAssertEqual(try options.resolve(result("generate", for: options)), .generate)
    }

    func testContinuationCannotSilentlyIgnoreAnAcceptedTask() throws {
        let snapshot = AccessibilitySnapshot(processID: 7, elements: [])
        let options = ComputerDecisionOptions(snapshot: snapshot, allowNativeActions: false, allowCompletion: false, allowIgnore: false)
        XCTAssertEqual(options.questions[0].choices.map(\.value), ["generate", "review"])
        XCTAssertEqual(options.questions[0].choices.count, 2)
        XCTAssertThrowsError(try options.resolve(result("ignore", for: options)))
        XCTAssertEqual(try options.resolve(result("generate", for: options)), .generate)
        XCTAssertEqual(try options.resolve(result("review", for: options)), .review)
    }

    func testActionLabelsAreShortSingleLineAndDoNotExposeFieldContents() throws {
        var field = control(id: "field", label: "private typed contents")
        field.role = "AXTextField"; field.value = "private typed contents"; field.help = "secret help"
        var sameAsValue = control(id: "same", label: "private value")
        sameAsValue.value = "private value"
        let long = control(id: "long", label: "\n\t" + String(repeating: "A very long title ", count: 20) + "\u{1B}")
        let options = options([field, sameAsValue, long])
        for element in [field, sameAsValue, long] {
            let decision = try options.resolve(result("ax:\(element.id):AXPress", for: options))
            guard case .native(_, _, let description) = decision else { return XCTFail("Expected native action") }
            XCTAssertLessThanOrEqual(description.count, 64)
            XCTAssertNil(description.rangeOfCharacter(from: .controlCharacters))
            XCTAssertFalse(description.contains("private"))
            XCTAssertFalse(description.contains("secret help"))
        }
        XCTAssertEqual(try options.resolve(result("ax:field:AXPress", for: options)), .native(field, action: "AXPress", description: "Clicking control…"))
        XCTAssertEqual(try options.resolve(result("ax:same:AXPress", for: options)), .native(sameAsValue, action: "AXPress", description: "Clicking button…"))
    }

    func testRejectsMalformedSelectionEvenIfConstructedWithoutNetworkClient() {
        let options = options([control(id: "a")])
        let valid = result("ax:a:AXPress", for: options)
        XCTAssertThrowsError(try options.resolve(DecisionResult(answers: [], inputTokens: 0, outputTokens: 0)))
        XCTAssertThrowsError(try options.resolve(DecisionResult(answers: valid.answers + valid.answers, inputTokens: 0, outputTokens: 0)))
        XCTAssertThrowsError(try options.resolve(result("ax:missing:AXPress", for: options)))
        XCTAssertThrowsError(try options.resolve(result("ax:a:AXRaise", for: options)))
        for confidence in [Double.nan, .infinity, -0.01, 1.01] {
            let malformed = DecisionResult(answers: [DecisionAnswer(name: options.questions[0].name, choice: "ax:a:AXPress", confidence: confidence)], inputTokens: 0, outputTokens: 0)
            XCTAssertThrowsError(try options.resolve(malformed))
        }
    }

    private func control(id: String, label: String = "Search", actions: [String] = ["AXPress"]) -> AccessibilityElement {
        AccessibilityElement(id: id, role: "AXButton", label: label, enabled: true, actions: actions,
                             screenshotBounds: AccessibilityBounds(x: 20, y: 30, width: 80, height: 30))
    }

    private func options(_ elements: [AccessibilityElement]) -> ComputerDecisionOptions {
        ComputerDecisionOptions(snapshot: AccessibilitySnapshot(processID: 7, elements: elements), allowNativeActions: true, allowCompletion: true)
    }

    private func nativeChoices(_ options: ComputerDecisionOptions) -> [DecisionChoice] {
        options.questions[0].choices.filter { $0.value.hasPrefix("ax:") }
    }

    private func result(_ choice: String, for options: ComputerDecisionOptions) -> DecisionResult {
        DecisionResult(answers: [DecisionAnswer(name: options.questions[0].name, choice: choice, confidence: 0.95)], inputTokens: 10, outputTokens: 0)
    }
}
