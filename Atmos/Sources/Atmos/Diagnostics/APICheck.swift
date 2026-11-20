import AppKit
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// Explicit opt-in smoke test: sends a generated fixture, never the user's screen,
/// and validates the model's click without posting any desktop events.
@MainActor enum APICheck {
    static func run(apiKey: String? = nil) async throws {
        guard let key = try apiKey ?? KeychainStore.openAI.load() else { throw AtmosError.configuration("No API key is configured.") }
        let frame = try fixtureFrame(completed: false)
        let completedFrame = try fixtureFrame(completed: true)
        let storage = UsageStorage()
        let usageURL = storage.usageURL
        var canPersistUsage = true
        var budget = loadUsage(from: storage, canPersist: &canPersistUsage)
        let start = Date()
        let client = OpenAIComputerClient(apiKey: key)
        countRequest(&budget, at: usageURL, canPersist: &canPersistUsage)
        var turn = try await client.begin(command: "Click the center of the blue TEST button exactly once using execute_actions. Only report done after the next screenshot shows the green DONE button.", frame: frame, context: "This is a generated test screen. You may request a screenshot before clicking. Do not type or use any other action.")
        var inputTokens = 0
        var outputTokens = 0
        var clicked = false
        for requestNumber in 1...3 {
            budget.record(turn)
            persistUsage(budget, at: usageURL, canPersist: &canPersistUsage)
            inputTokens += turn.inputTokens
            outputTokens += turn.outputTokens
            let actions = turn.calls.flatMap(\.actions)
            guard turn.pauseReason == nil else {
                throw failure("The fixture requested user input or review.", turn: turn)
            }
            if clicked {
                guard turn.calls.isEmpty, !turn.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw failure("The model did not finish after observing the completed fixture.", turn: turn)
                }
                print("PASS: Luna returned a grounded structured click and completed after the function-result screenshot.")
                print("No desktop input was executed. No real screen content was sent.")
                print("Requests: \(requestNumber). Tokens: \(inputTokens) input, \(outputTokens) output. Duration: \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")
                return
            }
            guard turn.calls.allSatisfy({ !$0.description.isEmpty && $0.description.count <= 64 }) else {
                throw failure("The fixture is missing a short action description.", turn: turn)
            }
            guard !actions.isEmpty, actions.allSatisfy({ $0.type == "screenshot" || $0.type == "click" }) else {
                throw failure("The model returned no click or requested an unexpected fixture action.", turn: turn)
            }
            let clicks = actions.filter { $0.type == "click" }
            if !clicks.isEmpty {
                guard clicks.count == 1, let action = clicks.first,
                      action.button == "left", action.keys?.isEmpty == true,
                      let x = action.x, let y = action.y,
                      let point = try? frame.screenPoint(x: x, y: y),
                      (140..<340).contains(point.x), (130..<190).contains(point.y) else {
                    throw failure("The model did not return exactly one left click inside the test button.", turn: turn)
                }
                clicked = true
            }
            // Return generated screens only. The second fixture simulates the button's
            // changed state so this check also verifies image-bearing function results.
            guard requestNumber < 3 else {
                throw failure("The model did not finish the fixture within three requests.", turn: turn)
            }
            let nextFrame = clicked ? completedFrame : frame
            let outputs = turn.calls.map { (callID: $0.callID, frame: nextFrame) }
            countRequest(&budget, at: usageURL, canPersist: &canPersistUsage)
            turn = try await client.continueTurn(responseID: turn.id, outputs: outputs)
        }
    }

    private static func fixtureFrame(completed: Bool) throws -> ScreenshotFrame {
        let image = NSImage(size: NSSize(width: 480, height: 320))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 480, height: 320).fill()
        (completed ? NSColor.systemGreen : NSColor.systemBlue).setFill()
        NSBezierPath(roundedRect: NSRect(x: 140, y: 130, width: 200, height: 60), xRadius: 12, yRadius: 12).fill()
        let label = (completed ? "DONE" : "TEST") as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: 240 - size.width / 2, y: 160 - size.height / 2), withAttributes: attributes)
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw AtmosError.configuration("Could not create API test image.") }
        return ScreenshotFrame(data: try NativeComputer.encodeJPEG(cgImage), width: cgImage.width, height: cgImage.height, pointWidth: 480, pointHeight: 320)
    }

    private static func loadUsage(from storage: UsageStorage, canPersist: inout Bool) -> DemoBudget {
        let url = storage.usageURL
        do {
            try storage.prepare()
            guard FileManager.default.fileExists(atPath: url.path) else { return DemoBudget() }
            do {
                return try JSONDecoder().decode(DemoBudget.self, from: Data(contentsOf: url))
            } catch {
                let backup = url.deletingLastPathComponent().appendingPathComponent("usage-unreadable-\(UUID().uuidString).json")
                try FileManager.default.copyItem(at: url, to: backup)
                print("Usage history could not be read. The previous file was preserved; a new counter will be used.")
                return DemoBudget()
            }
        } catch {
            canPersist = false
            print("Usage history is unavailable. This run will count in memory; API requests remain enabled.")
            return DemoBudget()
        }
    }

    private static func countRequest(_ budget: inout DemoBudget, at url: URL, canPersist: inout Bool) {
        budget.reserve()
        persistUsage(budget, at: url, canPersist: &canPersist)
    }

    private static func persistUsage(_ budget: DemoBudget, at url: URL, canPersist: inout Bool) {
        guard canPersist else { return }
        do { try JSONEncoder().encode(budget).write(to: url, options: .atomic) }
        catch {
            canPersist = false
            print("Usage could not be saved. This run will continue counting in memory; API requests remain enabled.")
        }
    }

    private static func failure(_ reason: String, turn: ModelTurn) -> AtmosError {
        let types = turn.calls.flatMap(\.actions).map(\.type).joined(separator: ", ")
        let message = turn.message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        print("Fixture action types: \(types.isEmpty ? "(none)" : types)")
        print("Fixture model message: \(message.isEmpty ? "(none)" : String(message.prefix(280)))")
        return .api(reason)
    }
}
