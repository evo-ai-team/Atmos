import XCTest
@testable import MouseCore

final class AccessibilityTraversalQueueTests: XCTestCase {
    func testLayoutWrappersDoNotHideADeepLinkWithUnusedNodeBudget() {
        // A native inspector can collapse layout groups that still exist in the
        // raw AXChildren hierarchy. Model that difference with a modest page
        // wrapped in many single-child containers, rather than a large page.
        struct Node { let id: Int; let depth: Int }
        func walk(wrapperCount: Int, oldDepthCutoff: Int?) -> Set<Int> {
            var queue = AccessibilityTraversalQueue<Node>()
            _ = queue.enqueue(Node(id: 0, depth: 0), priority: .root)
            var visited: Set<Int> = []
            while let node = queue.next() {
                visited.insert(node.id)
                if let oldDepthCutoff, node.depth >= oldDepthCutoff { continue }
                if node.id < wrapperCount {
                    _ = queue.enqueue(Node(id: node.id + 1, depth: node.depth + 1), priority: .content)
                }
            }
            return visited
        }
        let linkID = 38
        let old = walk(wrapperCount: linkID, oldDepthCutoff: 14)
        XCTAssertFalse(old.contains(linkID))
        XCTAssertEqual(old.count, 15)
        let current = walk(wrapperCount: linkID, oldDepthCutoff: nil)
        XCTAssertTrue(current.contains(linkID))
        XCTAssertEqual(current.count, 39)
        // Dropping the depth cutoff does not create an unbounded traversal even
        // for a pathological chain: processed ancestors still consume capacity.
        XCTAssertEqual(walk(wrapperCount: 1_000, oldDepthCutoff: nil).count, 600)
    }

    func testObservedWindowTopologyReachesTopicControlsWithProductionBudget() {
        // Sanitized 2026-10-20 Chrome/YouTube inspection: hierarchy depths only,
        // without page text, URLs, tab names, values, or native handles. This is
        // an inspector-derived fixture, not a claim of a live Mouse AX capture.
        let depths = [
            0,1,2,3,4,4,4,4,5,5,5,5,4,5,5,4,4,4,3,4,5,6,7,8,9,9,9,10,8,9,10,10,9,10,10,8,9,10,9,
            7,8,9,10,11,11,12,13,11,11,11,10,11,11,10,11,10,11,11,11,11,12,13,14,10,11,10,11,11,11,11,
            10,11,10,11,11,11,11,11,11,11,10,11,11,11,11,11,11,10,7,8,9,10,11,12,11,12,11,12,11,12,
            11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,11,12,
            10,11,11,9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,
            9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,
            9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,
            9,10,10,11,10,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,10,11,10,11,10,
            9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,10,11,10,11,10,
            9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,
            9,10,10,11,10,10,10,11,10,11,10,9,10,10,11,10,10,10,11,10,11,10,9,10,10,11,10,10,11,10,11,10,
            9,10,10,11,10,10,10,11,10,11,10,9,10,10,11,10,10,10,11,10,11,10,9,10,10,11,10,10,10,11,10,11,10,
            7,8,9,10,11,3,3,4,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,
            5,5,5,5,5,5,5,5,5,5,5,5,5,5,6,3,1,1,1
        ]
        XCTAssertEqual(depths.count, 441)
        var children: [Int: [Int]] = [:]
        var parents: [Int] = []
        for index in depths.indices {
            while let parent = parents.last, depths[parent] >= depths[index] { parents.removeLast() }
            if let parent = parents.last { children[parent, default: []].append(index) }
            parents.append(index)
        }
        struct Node { let id: Int; let content: Bool }
        func walk(oldLimit: Bool, contentPriority: Bool) -> Set<Int> {
            var queue = oldLimit ? AccessibilityTraversalQueue<Node>(limit: 220) : AccessibilityTraversalQueue<Node>()
            _ = queue.enqueue(Node(id: 0, content: false), priority: .root)
            var seen: Set<Int> = []
            while let node = queue.next() {
                seen.insert(node.id)
                let role = node.id == 20 ? "AXWebArea" : node.id == 19 ? "AXScrollArea" : "AXGroup"
                let content = contentPriority && AccessibilityTraversalQueue<Node>.isContentRegion(role: role, inherited: node.content)
                for id in children[node.id, default: []].prefix(48) {
                    _ = queue.enqueue(Node(id: id, content: content), priority: content ? .content : .window)
                }
            }
            return seen
        }
        // Merely changing priority at the old cap still misses both topic tabs.
        for prioritize in [false, true] {
            let old = walk(oldLimit: true, contentPriority: prioritize)
            XCTAssertFalse(old.contains(94)) // Gaming topic
            XCTAssertFalse(old.contains(102)) // Pokémon topic
            XCTAssertTrue(old.contains(437)) // New Tab in the browser toolbar
        }
        let current = walk(oldLimit: false, contentPriority: true)
        XCTAssertTrue(current.isSuperset(of: [94, 102, 437]))
        XCTAssertEqual(current.count, 441)
    }

    func testWideMenusCannotStarveADeepWindowButtonAndTopMenusRemainAvailable() {
        // With one FIFO and a 220-enqueued cap, these menu branches exhaust the
        // walk before wrapper 4. Exercise the production queue with the same tree.
        struct Node { let id: String; let depth: Int; let menu: Bool }
        var tree: [String: [String]] = ["window": ["w1"], "menubar": (0..<10).map { "m\($0)" }]
        for depth in 1...8 { tree["w\(depth)"] = [depth == 8 ? "button" : "w\(depth + 1)"] }
        for menu in 0..<10 {
            tree["m\(menu)"] = ["menu\(menu)"]
            tree["menu\(menu)"] = (0..<24).map { "item\(menu)_\($0)" }
        }
        var queue = AccessibilityTraversalQueue<Node>(limit: 220)
        _ = queue.enqueue(Node(id: "window", depth: 0, menu: false), priority: .root)
        _ = queue.enqueue(Node(id: "menubar", depth: 0, menu: true), priority: .root)
        var visited: [String] = []
        while let node = queue.next() {
            visited.append(node.id)
            for id in tree[node.id, default: []] {
                let child = Node(id: id, depth: node.depth + 1, menu: node.menu)
                let priority: AccessibilityTraversalQueue<Node>.Priority = child.menu
                    ? (child.depth == 1 ? .menuBar : .menuContents) : .window
                _ = queue.enqueue(child, priority: priority)
            }
        }
        XCTAssertTrue(visited.contains("button"))
        for menu in 0..<10 { XCTAssertTrue(visited.contains("m\(menu)")) }
        XCTAssertEqual(visited.count, 220)
        XCTAssertEqual(queue.processedCount, 220)
        XCTAssertGreaterThan(queue.omittedCount, 0)
        XCTAssertLessThan(visited.firstIndex(of: "button")!, visited.firstIndex(of: "menu0")!)
    }

    func testPendingMenuReservationCanBeReplacedButAlreadyProcessedWorkStillCounts() {
        var queue = AccessibilityTraversalQueue<String>(limit: 3)
        _ = queue.enqueue("window", priority: .window)
        _ = queue.enqueue("menu1", priority: .menuContents)
        _ = queue.enqueue("menu2", priority: .menuContents)
        XCTAssertEqual(queue.next(), "window")
        if case let .replaced(value) = queue.enqueue("deepButton", priority: .window) {
            XCTAssertEqual(value, "menu2")
        } else { XCTFail("A pending menu must not reserve the window's final slot.") }
        XCTAssertEqual(queue.next(), "deepButton")
        XCTAssertEqual(queue.next(), "menu1")
        if case .rejected = queue.enqueue("extra", priority: .root) {} else { XCTFail("Processed work still consumes the cap.") }
        XCTAssertNil(queue.next())
        XCTAssertEqual(queue.processedCount, 3)
    }

    func testDeepContentSurvivesWideAppNavigationWithoutLosingToolbarOrTopMenus() {
        struct Node { let id: String; let depth: Int; let menu: Bool; let content: Bool }
        // The content button is at depth 11. Its AXWebArea is discovered before
        // thirty shallow navigation groups fill the queue with 300 other controls.
        // A window-only FIFO finds the web area but cannot finish its descendants.
        var tree: [String: [String]] = [
            "window": ["toolbar", "frame"],
            "toolbar": ["newTab"] + (0..<10).map { "chrome\($0)" },
            "frame": ["contentWrapper", "navigation"],
            "contentWrapper": ["contentRegion"],
            "contentRegion": ["article1"],
            "navigation": (0..<30).map { "group\($0)" },
            "menubar": ["fileMenu", "editMenu"]
        ]
        for group in 0..<30 { tree["group\(group)"] = (0..<10).map { "nav\(group)_\($0)" } }
        for depth in 1...7 { tree["article\(depth)"] = [depth == 7 ? "contentButton" : "article\(depth + 1)"] }

        func walk(regionRole: String, prioritizeContent: Bool) -> (visited: Set<String>, count: Int, omitted: Int, targetDepth: Int?) {
            var queue = AccessibilityTraversalQueue<Node>(limit: 220)
            _ = queue.enqueue(Node(id: "window", depth: 0, menu: false, content: false), priority: .root)
            _ = queue.enqueue(Node(id: "menubar", depth: 0, menu: true, content: false), priority: .root)
            var visited: Set<String> = []
            var targetDepth: Int?
            while let node = queue.next() {
                visited.insert(node.id)
                if node.id == "contentButton" { targetDepth = node.depth }
                let role = node.id == "contentRegion" ? regionRole : "AXGroup"
                let content = prioritizeContent && AccessibilityTraversalQueue<Node>.isContentRegion(role: role, inherited: node.content)
                for id in tree[node.id, default: []] {
                    let child = Node(id: id, depth: node.depth + 1, menu: node.menu, content: content)
                    let priority: AccessibilityTraversalQueue<Node>.Priority = child.menu
                        ? (child.depth == 1 ? .menuBar : .menuContents) : (child.content ? .content : .window)
                    _ = queue.enqueue(child, priority: priority)
                }
            }
            return (visited, queue.processedCount, queue.omittedCount, targetDepth)
        }

        let oldWindowOrder = walk(regionRole: "AXWebArea", prioritizeContent: false)
        XCTAssertFalse(oldWindowOrder.visited.contains("contentButton"))
        XCTAssertTrue(oldWindowOrder.visited.contains("contentRegion"))
        for role in ["AXWebArea", "AXScrollArea", "AXOutline", "AXTable", "AXTextArea"] {
            let result = walk(regionRole: role, prioritizeContent: true)
            XCTAssertEqual(result.targetDepth, 11, role)
            XCTAssertTrue(result.visited.isSuperset(of: ["newTab", "toolbar", "fileMenu", "editMenu"]), role)
            XCTAssertEqual(result.count, 220, role)
            XCTAssertGreaterThan(result.omitted, 0, role)
        }
    }
}
