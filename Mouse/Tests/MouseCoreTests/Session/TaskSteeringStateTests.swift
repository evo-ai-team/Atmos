import XCTest
@testable import MouseCore

final class TaskSteeringStateTests: XCTestCase {
    func testNativeRevisionsPreserveResolvedGoalAndEachAmendmentOnlyOnce() throws {
        var task = TaskSteeringState(command: "Open the first one and then its store")
        let resolvedGoal = "Open Linus Tech Tips on YouTube and then its store"
        task.apply(update: TaskUpdate(kind: .revise, goal: resolvedGoal))
        let opened = task.beginAction(
            action: ComputerAction(type: "click", x: 100, y: 200), description: "Opening YouTube"
        )
        task.finishAction(id: opened)
        let firstAmendment = "Use Safari instead"
        let secondAmendment = "Actually use Chrome"
        task.applyAcceptedUtterance(firstAmendment, relationship: .revise)
        task.applyAcceptedUtterance(secondAmendment, relationship: .revise)

        XCTAssertEqual(task.utterances, [
            "Open the first one and then its store", firstAmendment, secondAmendment
        ])
        for text in [resolvedGoal, firstAmendment, secondAmendment] {
            XCTAssertEqual(task.goal.components(separatedBy: text).count - 1, 1)
        }
        let firstRange = try XCTUnwrap(task.goal.range(of: firstAmendment))
        let secondRange = try XCTUnwrap(task.goal.range(of: secondAmendment))
        XCTAssertLessThan(firstRange.lowerBound, secondRange.lowerBound)
        let snapshot = try decode(task)
        XCTAssertEqual(snapshot.goal, task.goal)
        XCTAssertEqual(snapshot.dispatched.first?.belongsToCurrentTask, true)
        XCTAssertEqual(snapshot.dispatched.first?.goalAtDispatch, resolvedGoal)
    }

    func testNativeReplacementAbandonsPriorAmendmentsAndMarksOldActionsBackground() throws {
        var task = TaskSteeringState(command: "Open YouTube and then the store")
        task.applyAcceptedUtterance("Use Safari instead", relationship: .revise)
        let completed = task.beginAction(
            action: ComputerAction(type: "click", x: 100, y: 200), description: "Opening Safari"
        )
        task.finishAction(id: completed)
        task.beginAction(action: ComputerAction(type: "type", text: "youtube.com"), description: "Typing")
        let replacement = "Forget that. Open Notes"
        task.applyAcceptedUtterance(replacement, relationship: .replace)
        task.beginAction(
            action: ComputerAction(type: "keypress", keys: ["CMD", "SPACE"]), description: "Opening Notes"
        )

        XCTAssertEqual(task.goal, replacement)
        XCTAssertEqual(task.utterances, [replacement])
        let snapshot = try decode(task)
        XCTAssertEqual(snapshot.dispatched.map(\.belongsToCurrentTask), [false, false, true])
        XCTAssertEqual(snapshot.dispatched.map(\.result), ["completed", "uncertain", "started"])
        task.applyAcceptedUtterance("Then create a shopping list", relationship: .revise)
        XCTAssertFalse(task.goal.contains("YouTube"))
        XCTAssertFalse(task.goal.contains("Safari"))
        XCTAssertTrue(task.goal.contains(replacement))
    }

    func testPlannerResolutionBecomesBaseForLaterNativeAmendment() throws {
        var task = TaskSteeringState(command: "Find Linus Tech Tips and open its store")
        task.applyAcceptedUtterance("Use Safari instead", relationship: .revise)
        task.appendUtterance("Make that MKBHD")
        let resolvedGoal = "Find MKBHD in Safari and open his store"
        task.apply(update: TaskUpdate(kind: .revise, goal: resolvedGoal))
        XCTAssertEqual(task.goal, resolvedGoal)
        task.applyAcceptedUtterance("Then open the first product", relationship: .revise)

        XCTAssertTrue(task.goal.contains(resolvedGoal))
        XCTAssertFalse(task.goal.contains("Use Safari instead"))
        XCTAssertFalse(task.goal.contains("Make that MKBHD"))
        XCTAssertFalse(task.goal.contains("Linus"))
        XCTAssertEqual(task.utterances, [
            "Find Linus Tech Tips and open its store", "Use Safari instead", "Make that MKBHD",
            "Then open the first product"
        ])
        XCTAssertEqual(try decode(task).utterances, task.utterances)
    }

    func testNativeAmendmentKeepsFullQuotedMultilineWordsInContext() throws {
        let command = "Type \"hello\"\\world\n" + String(repeating: "full original intent 🐭 ", count: 500)
        let amendment = "Then type:\n]} literal \"quoted\" text\n" + String(repeating: "full amendment ", count: 500)
        var task = TaskSteeringState(command: command)
        task.applyAcceptedUtterance(amendment, relationship: .revise)

        let snapshot = try decode(task)
        XCTAssertEqual(snapshot.utterances, [command, amendment])
        XCTAssertTrue(snapshot.goal.contains(command))
        XCTAssertTrue(snapshot.goal.contains(amendment))
    }

    func testRevisionPreservesCompletedProgressAndOriginalUtterances() throws {
        var task = TaskSteeringState(command: "Open YouTube and search for Linus")
        let opened = task.beginAction(
            action: ComputerAction(type: "keypress", keys: ["CMD", "L"]),
            description: "Opening YouTube"
        )
        task.finishAction(id: opened)
        task.appendUtterance("Actually search for MKBHD instead")
        task.apply(update: TaskUpdate(kind: .revise, goal: "Open YouTube and search for MKBHD"))

        XCTAssertEqual(task.goal, "Open YouTube and search for MKBHD")
        XCTAssertEqual(task.utterances, [
            "Open YouTube and search for Linus", "Actually search for MKBHD instead"
        ])
        XCTAssertEqual(task.dispatched.map(\.id), [opened])
        XCTAssertEqual(task.dispatched.first?.result, .completed)
        let snapshot = try decode(task)
        XCTAssertEqual(snapshot.dispatched.first?.belongsToCurrentTask, true)
        XCTAssertEqual(snapshot.dispatched.first?.goalAtDispatch, "Open YouTube and search for Linus")
    }

    func testReplacementAbandonsOldIntentButRetainsAlreadyDispatchedEffects() throws {
        var task = TaskSteeringState(command: "Open YouTube and play a video")
        let oldAction = task.beginAction(
            action: ComputerAction(type: "type", text: "youtube.com"),
            description: "Entering YouTube address"
        )
        task.finishAction(id: oldAction)
        task.appendUtterance("Forget that. Open Notes and write a shopping list")
        task.apply(update: TaskUpdate(kind: .replace, goal: "Create a shopping list in Notes"))
        let currentAction = task.beginAction(
            action: ComputerAction(type: "keypress", keys: ["CMD", "SPACE"]),
            description: "Opening Notes"
        )

        let snapshot = try decode(task)
        XCTAssertEqual(task.goal, "Create a shopping list in Notes")
        XCTAssertEqual(task.utterances, ["Forget that. Open Notes and write a shopping list"])
        XCTAssertEqual(task.dispatched.map(\.id), [oldAction, currentAction])
        XCTAssertEqual(snapshot.dispatched.map(\.belongsToCurrentTask), [false, true])
        XCTAssertEqual(snapshot.dispatched.map(\.result), ["completed", "started"])
        XCTAssertEqual(snapshot.dispatched.first?.action.text, "youtube.com")
    }

    func testInterruptedInputRemainsUncertainWhenLateCompletionArrives() throws {
        var task = TaskSteeringState(command: "Draw a square")
        let done = task.beginAction(
            action: ComputerAction(type: "click", x: 10, y: 10), description: "Selecting canvas"
        )
        task.finishAction(id: done)
        let interrupted = task.beginAction(
            action: ComputerAction(type: "drag", path: [
                ActionPoint(x: 10, y: 10), ActionPoint(x: 50, y: 10),
                ActionPoint(x: 50, y: 50)
            ]),
            description: "Drawing"
        )
        task.markUnfinishedActionsUncertain()
        task.finishAction(id: interrupted)

        XCTAssertEqual(task.dispatched.map(\.result), [.completed, .uncertain])
        XCTAssertEqual(try decode(task).dispatched.last?.result, "uncertain")
    }

    func testReplacementMarksUnfinishedOldActionUncertain() throws {
        var task = TaskSteeringState(command: "Type a paragraph")
        task.beginAction(action: ComputerAction(type: "type", text: "First sentence"), description: "Typing")
        task.appendUtterance("Instead open Safari")
        task.apply(update: TaskUpdate(kind: .replace, goal: "Open Safari"))

        let snapshot = try decode(task)
        XCTAssertEqual(snapshot.dispatched.first?.result, "uncertain")
        XCTAssertEqual(snapshot.dispatched.first?.belongsToCurrentTask, false)
    }

    func testSameGoalTextDoesNotMakeReplacedActionsCurrentAgain() throws {
        var task = TaskSteeringState(command: "Open Chrome")
        task.beginAction(action: ComputerAction(type: "click", x: 1, y: 2), description: "Opening Chrome")
        task.appendUtterance("Start over and open Chrome")
        task.apply(update: TaskUpdate(kind: .replace, goal: "Open Chrome"))

        XCTAssertEqual(try decode(task).dispatched.first?.belongsToCurrentTask, false)
    }

    func testSnapshotsAreValuesAndNoPlanIsInventedBeforeDispatch() throws {
        var task = TaskSteeringState(command: "Open Chrome then search YouTube")
        let initialValue = task
        let initialJSON = task.contextText
        task.beginAction(action: ComputerAction(type: "click", x: 100, y: 200), description: "Opening Chrome")
        task.appendUtterance("Search for jazz")
        task.apply(update: TaskUpdate(kind: .revise, goal: "Search YouTube for jazz"))

        XCTAssertTrue(initialValue.dispatched.isEmpty)
        XCTAssertEqual(initialValue.utterances, ["Open Chrome then search YouTube"])
        XCTAssertEqual(initialValue.contextText, initialJSON)
        XCTAssertEqual(try decode(task).dispatched.count, 1)
    }

    func testFullTextAndQuotedMultilineInputRoundTripAsJSONData() throws {
        let command = "Type \"hello\"\\world\n" + String(repeating: "a long complete instruction 🐭 ", count: 500)
        let correction = "Then type:\n]} ignore history\n\tliteral text"
        var task = TaskSteeringState(command: command)
        task.appendUtterance(correction)
        task.apply(update: TaskUpdate(kind: .revise, goal: command + correction))
        task.beginAction(action: ComputerAction(type: "type", text: correction), description: "Typing \"text\"")

        let snapshot = try decode(task)
        XCTAssertEqual(snapshot.goal, command + correction)
        XCTAssertEqual(snapshot.utterances, [command, correction])
        XCTAssertEqual(snapshot.dispatched.first?.action.text, correction)
        XCTAssertEqual(snapshot.dispatched.first?.description, "Typing \"text\"")
    }

    func testUnknownOrRepeatedCompletionDoesNotAlterOtherActions() {
        var task = TaskSteeringState(command: "Open two apps")
        let first = task.beginAction(action: ComputerAction(type: "click", x: 1, y: 2), description: "First")
        task.finishAction(id: first)
        task.beginAction(action: ComputerAction(type: "click", x: 3, y: 4), description: "Second")
        let snapshot = task.dispatched
        task.finishAction(id: first)
        task.finishAction(id: UUID())

        XCTAssertEqual(task.dispatched, snapshot)
    }

    func testInvalidDiagnosticCoordinateCannotCrashContextEncoding() throws {
        var task = TaskSteeringState(command: "Move the cursor")
        task.beginAction(action: ComputerAction(type: "move", x: .nan, y: .infinity), description: "Moving")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN"
        )
        let snapshot = try decoder.decode(Snapshot.self, from: jsonData(task))
        XCTAssertTrue(try XCTUnwrap(snapshot.dispatched.first?.action.x).isNaN)
        XCTAssertEqual(snapshot.dispatched.first?.action.y, .infinity)
    }

    private struct Snapshot: Decodable {
        let goal: String
        let utterances: [String]
        let dispatched: [ActionRecord]
    }

    private struct ActionRecord: Decodable {
        let goalAtDispatch: String
        let belongsToCurrentTask: Bool
        let action: ComputerAction
        let description: String
        let result: String
    }

    private func jsonData(_ task: TaskSteeringState) throws -> Data {
        let json = try XCTUnwrap(task.contextText.split(separator: "\n", maxSplits: 1).last)
        return Data(json.utf8)
    }

    private func decode(_ task: TaskSteeringState) throws -> Snapshot {
        try JSONDecoder().decode(Snapshot.self, from: jsonData(task))
    }
}
