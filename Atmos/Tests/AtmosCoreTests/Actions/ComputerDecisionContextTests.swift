import XCTest
@testable import AtmosCore

final class ComputerDecisionContextTests: XCTestCase {
    func testIntentAmendmentsAndRecentReferentsRemainWholeWhileOldHistoryIsBounded() throws {
        let original = "Open this exact document:\n" + String(repeating: "full intent 🐭 ", count: 400)
        let amendment = "Then copy its \"second section\", preserving all formatting."
        var task = TaskSteeringState(command: original)
        task.applyAcceptedUtterance(amendment, relationship: .revise)
        var history = CommandContext()
        for index in 0..<4 { history.begin(command: "Old command \(index)") }
        let referent = "Open that one " + String(repeating: "full reference ", count: 400)
        let id = history.begin(command: referent, resolvedGoal: "Open Acme's second document")
        history.recordDispatchedAction(id: id, description: "Opening Acme's second document")
        history.finish(id: id, outcome: "Which section?", status: .paused)

        let context = ComputerDecisionContext(
            request: amendment, isContinuation: false, task: task,
            recentCommands: history.entries, pendingClarification: "Which section?", snapshot: snapshot([])
        )

        XCTAssertEqual(context.request, amendment)
        XCTAssertEqual(context.goal, task.goal)
        XCTAssertTrue(try XCTUnwrap(context.goal).contains(original))
        XCTAssertTrue(try XCTUnwrap(context.goal).contains(amendment))
        XCTAssertEqual(context.recentCommands.map(\.command), ["Old command 2", "Old command 3", referent])
        XCTAssertEqual(context.omittedCommandCount, 2)
        XCTAssertEqual(context.recentCommands.last?.resolvedGoal, "Open Acme's second document")
        XCTAssertEqual(context.recentCommands.last?.lastDispatched, "Opening Acme's second document")
        XCTAssertEqual(context.recentCommands.last?.status, .paused)
        XCTAssertEqual(context.recentCommands.last?.outcome, "Which section?")
        XCTAssertEqual(context.pendingClarification, "Which section?")
    }

    func testDispatchProjectionKeepsUncertaintyAndTaskOwnershipWithoutActionPayloads() throws {
        var task = TaskSteeringState(command: "Old task")
        for index in 0..<14 {
            let id = task.beginAction(
                action: ComputerAction(type: "click", x: 1234567, y: 9876543), description: "Click \(index)"
            )
            task.finishAction(id: id)
        }
        task.beginAction(action: ComputerAction(type: "type", text: "PRIVATE_DISPATCH_TEXT"), description: "Typing")
        task.applyAcceptedUtterance("Instead open Notes", relationship: .replace)
        task.beginAction(action: ComputerAction(type: "keypress", keys: ["PRIVATE_KEY_VALUE"]), description: "Opening Notes")
        let context = ComputerDecisionContext(
            request: "Continue", isContinuation: true, task: task,
            recentCommands: [], pendingClarification: nil, snapshot: snapshot([])
        )

        XCTAssertEqual(context.progress.count, 12)
        XCTAssertEqual(context.omittedDispatchCount, 4)
        XCTAssertEqual(context.progress.first?.description, "Click 4")
        XCTAssertEqual(context.progress.suffix(2).map(\.result), [.uncertain, .started])
        XCTAssertEqual(context.progress.suffix(2).map(\.belongsToCurrentTask), [false, true])
        XCTAssertEqual(context.goal, "Instead open Notes")
        let json = try json(context)
        for privateValue in ["PRIVATE_DISPATCH_TEXT", "PRIVATE_KEY_VALUE", "1234567", "9876543", "goalAtDispatch", "Old task"] {
            XCTAssertFalse(json.contains(privateValue), privateValue)
        }
    }

    func testUIEvidenceRetainsVisibleStateAndTextWithoutRepeatingActionNamesOrGeometry() throws {
        let nodes = [
            node("private-window-id", role: "AXWindow", label: "Settings"),
            node("private-home-id", role: "AXButton", label: "Home", value: "Home", enabled: true, actions: ["AXPress"]),
            node("private-toggle-id", role: "AXCheckBox", label: "Notifications", value: "1", enabled: true, actions: ["AXPress"]),
            node("private-save-id", role: "AXButton", label: "Save", enabled: false, actions: ["AXPress"]),
            node("private-status-id", role: "AXStaticText", label: "Changes saved", value: "Changes saved"),
            node("private-empty-id", role: "AXGroup", label: "Unnecessary container"),
            AccessibilityElement(id: "private-offscreen-id", role: "AXStaticText", label: "Offscreen evidence")
        ]
        let context = context(snapshot(nodes))

        XCTAssertTrue(context.hasUIEvidence)
        XCTAssertEqual(context.ui.elements.map(\.label), ["Settings", "Notifications", "Save", "Changes saved"])
        XCTAssertEqual(context.ui.elements[1].value, "1")
        XCTAssertNil(context.ui.elements[1].enabled)
        XCTAssertEqual(context.ui.elements[2].enabled, false)
        XCTAssertNil(context.ui.elements[3].value)
        XCTAssertEqual(context.ui.omittedElementCount, 3)
        let json = try json(context)
        for excluded in ["private-", "screenBounds", "screenshotBounds", "capturedAt", "childIDs", "parentID", "processID", "PRIVATE_HELP"] {
            XCTAssertFalse(json.contains(excluded), excluded)
        }
        // The command itself still says "Click Home"; only its redundant UI
        // evidence row is omitted because the native option already names it.
        let uiJSON = String(decoding: try JSONEncoder().encode(context.ui), as: UTF8.self)
        XCTAssertFalse(uiJSON.contains("Home"))
        XCTAssertFalse(json.contains("Unnecessary container"))
        XCTAssertFalse(json.contains("Offscreen evidence"))
    }

    func testProtectedFieldsAreRedactedEvenWhenOnlySubroleMarksThemSecure() throws {
        var protected = node("secure", role: "AXTextField", label: "PRIVATE_LABEL", value: "PRIVATE_VALUE")
        protected.secure = true
        var subrole = node("subrole", role: "AXTextField", label: "PRIVATE_SUBROLE_LABEL", value: "PRIVATE_SUBROLE_VALUE")
        subrole.subrole = "AXSecureTextField"
        let role = node("role", role: "AXSecureTextField", label: "PRIVATE_ROLE_LABEL", value: "PRIVATE_ROLE_VALUE")
        let context = context(snapshot([protected, subrole, role]))

        XCTAssertFalse(context.hasUIEvidence)
        XCTAssertTrue(context.ui.elements.isEmpty)
        XCTAssertEqual(context.ui.redactedElementCount, 3)
        XCTAssertEqual(context.ui.omittedElementCount, 3)
        XCTAssertFalse(try json(context).contains("PRIVATE_"))
    }

    func testEvidenceCapKeepsLandmarksAndControlStateBeforeBodyText() {
        var nodes = (0..<120).map { node("text-\($0)", role: "AXStaticText", label: "Body \($0)") }
        nodes.append(node("title", role: "AXHeading", label: "Settings saved"))
        nodes.append(node("state", role: "AXCheckBox", label: "Enabled", value: "1", actions: ["AXPress"]))
        var capture = snapshot(nodes)
        capture.truncated = true
        let context = context(capture)

        XCTAssertEqual(context.ui.elements.count, 100)
        XCTAssertEqual(context.ui.elements.prefix(3).map(\.label), ["Settings saved", "Enabled", "Body 0"])
        XCTAssertEqual(context.ui.omittedElementCount, 22)
        XCTAssertTrue(context.ui.captureIncomplete)
    }

    func testSameNamedControlStatesKeepTheirSectionAssociation() {
        let window = node("window", role: "AXWindow", label: "Settings")
        var browser = node("browser", role: "AXGroup", label: "Browser")
        browser.parentID = window.id
        var system = node("system", role: "AXGroup", label: "System")
        system.parentID = window.id
        var browserSetting = node("browser-setting", role: "AXCheckBox", label: "Notifications", value: "1",
                                  enabled: true, actions: ["AXPress"])
        browserSetting.parentID = browser.id
        var systemSetting = node("system-setting", role: "AXCheckBox", label: "Notifications", value: "0",
                                 enabled: true, actions: ["AXPress"])
        systemSetting.parentID = system.id
        var browserStatus = node("browser-status", role: "AXStaticText", label: "Saved")
        browserStatus.parentID = browser.id
        var systemStatus = node("system-status", role: "AXStaticText", label: "Saved")
        systemStatus.parentID = system.id
        let context = context(snapshot([window, browser, system, browserSetting, systemSetting, browserStatus, systemStatus]))

        let settings = context.ui.elements.filter { $0.label == "Notifications" }
        XCTAssertEqual(settings.map(\.value), ["1", "0"])
        XCTAssertEqual(settings.map(\.within), [["Browser", "Settings"], ["System", "Settings"]])
        let statuses = context.ui.elements.filter { $0.label == "Saved" }
        XCTAssertEqual(statuses.map(\.within), [["Browser", "Settings"], ["System", "Settings"]])
    }

    func testStateAncestorContextRejectsProtectedAndAmbiguousNamesAndStopsCycles() throws {
        var secure = node("secure-parent", role: "AXGroup", label: "PRIVATE_ANCESTOR")
        secure.subrole = "AXSecureTextField"
        var state = node("state", role: "AXCheckBox", label: "Enabled", value: "1")
        state.parentID = secure.id
        var duplicateA = node("duplicate-parent", role: "AXGroup", label: "Ambiguous first")
        duplicateA.parentID = secure.id
        let duplicateB = node("duplicate-parent", role: "AXGroup", label: "Ambiguous second")
        var ambiguousState = node("ambiguous-state", role: "AXCheckBox", label: "Enabled", value: "0")
        ambiguousState.parentID = duplicateA.id
        var cycle = node("cycle-parent", role: "AXGroup", label: "Panel")
        var cyclicState = node("cyclic-state", role: "AXCheckBox", label: "Enabled", value: "1")
        cycle.parentID = cyclicState.id
        cyclicState.parentID = cycle.id
        let context = context(snapshot([secure, state, duplicateA, duplicateB, ambiguousState, cycle, cyclicState]))

        XCTAssertEqual(context.ui.elements.map(\.within), [nil, nil, ["Panel"]])
        let json = try json(context)
        XCTAssertFalse(json.contains("PRIVATE_ANCESTOR"))
        XCTAssertFalse(json.contains("Ambiguous"))
    }

    func testUnavailableDuplicateAndCyclicSnapshotsCannotInventEvidenceOrRecurse() {
        var cyclic = node("cycle", role: "AXStaticText", label: "Current status")
        cyclic.parentID = "cycle"
        cyclic.childIDs = ["cycle"]
        cyclic.childrenTruncated = true
        let duplicateA = node("duplicate", role: "AXStaticText", label: "Conflicting first status")
        let duplicateB = node("duplicate", role: "AXStaticText", label: "Conflicting second status")
        let unnamed = node("", role: "AXStaticText", label: "No identity")
        var capture = snapshot([cyclic, duplicateA, duplicateB, unnamed])
        let available = context(capture)

        XCTAssertEqual(available.ui.elements.map(\.label), ["Current status"])
        XCTAssertEqual(available.ui.omittedElementCount, 3)
        XCTAssertTrue(available.ui.captureIncomplete)
        capture.unavailableReason = "Capture unavailable"
        let unavailable = context(capture)
        XCTAssertTrue(unavailable.ui.unavailable)
        XCTAssertFalse(unavailable.hasUIEvidence)
        XCTAssertTrue(unavailable.ui.elements.isEmpty)
        XCTAssertEqual(unavailable.ui.omittedElementCount, 4)
    }

    func testRepeatedResolvedGoalIsOmittedButCurrentRequestIsNeverRewritten() throws {
        var history = CommandContext()
        history.begin(command: "Open Home", resolvedGoal: "Open Home")
        let context = ComputerDecisionContext(
            request: "  and then his store\n", isContinuation: false, task: nil,
            recentCommands: history.entries, pendingClarification: nil, snapshot: snapshot([])
        )

        XCTAssertEqual(context.request, "  and then his store\n")
        XCTAssertNil(context.recentCommands.first?.resolvedGoal)
        XCTAssertNil(context.goal)
        XCTAssertFalse(try json(context).contains("resolvedGoal"))
    }

    func testContinuationSendsTheFullGoalOnceWithoutInventingANewRequest() throws {
        let goal = "Open the exact requested document and preserve all edits."
        let context = ComputerDecisionContext(
            request: goal, isContinuation: true, task: TaskSteeringState(command: goal),
            recentCommands: [], pendingClarification: nil, snapshot: snapshot([])
        )
        XCTAssertTrue(context.isContinuation)
        XCTAssertNil(context.request)
        XCTAssertEqual(context.goal, goal)
        XCTAssertEqual(try json(context).components(separatedBy: goal).count - 1, 1)
    }

    private func node(_ id: String, role: String, label: String? = nil, value: String? = nil,
                      enabled: Bool? = nil, actions: [String] = []) -> AccessibilityElement {
        AccessibilityElement(
            id: id, role: role, label: label, value: value, help: "PRIVATE_HELP",
            enabled: enabled, actions: actions,
            screenBounds: AccessibilityBounds(x: 25, y: 25, width: 100, height: 30),
            screenshotBounds: AccessibilityBounds(x: 25, y: 25, width: 100, height: 30)
        )
    }

    private func snapshot(_ nodes: [AccessibilityElement]) -> AccessibilitySnapshot {
        AccessibilitySnapshot(processID: 12345, elements: nodes)
    }

    private func context(_ snapshot: AccessibilitySnapshot) -> ComputerDecisionContext {
        ComputerDecisionContext(request: "Click Home", isContinuation: false, task: nil,
                                recentCommands: [], pendingClarification: nil, snapshot: snapshot)
    }

    private func json(_ context: ComputerDecisionContext) throws -> String {
        String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
    }
}
