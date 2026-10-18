import AppKit
#if SWIFT_PACKAGE
import ChosenCore
#endif

/// Explicit opt-in smoke test: sends a generated fixture, never the user's screen,
/// and validates the model's click without posting any desktop events.
@MainActor enum APICheck {
    static func run(apiKey: String? = nil) async throws {
        guard let key = try apiKey ?? KeychainStore.load() else { throw ChosenError.configuration("No API key is configured.") }
        let image = NSImage(size: NSSize(width: 480, height: 320))
        image.lockFocus()
        NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 480, height: 320).fill()
        NSColor.systemBlue.setFill(); NSBezierPath(roundedRect: NSRect(x: 140, y: 130, width: 200, height: 60), xRadius: 12, yRadius: 12).fill()
        let label = "TEST" as NSString
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 24, weight: .bold), .foregroundColor: NSColor.white]
        let size = label.size(withAttributes: attributes)
        label.draw(at: NSPoint(x: 240 - size.width / 2, y: 160 - size.height / 2), withAttributes: attributes)
        image.unlockFocus()
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw ChosenError.configuration("Could not create API test image.") }
        let frame = ScreenshotFrame(data: try NativeComputer.encodeJPEG(cgImage), width: cgImage.width, height: cgImage.height, pointWidth: 480, pointHeight: 320)
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Chosen", isDirectory: true)
        let usageURL = directory.appendingPathComponent("usage.json")
        var canPersistUsage = true
        var budget = loadUsage(at: usageURL, canPersist: &canPersistUsage)
        let start = Date()
        let client = OpenAIComputerClient(apiKey: key)
        countRequest(&budget, at: usageURL, canPersist: &canPersistUsage)
        var turn = try await client.begin(command: "Click the center of the blue TEST button exactly once. Use the computer tool.", frame: frame, context: "This is a generated test screen. You may request a screenshot before clicking. Do not type or use any other action.")
        var inputTokens = 0
        var outputTokens = 0
        for requestNumber in 1...3 {
            budget.record(turn)
            persistUsage(budget, at: usageURL, canPersist: &canPersistUsage)
            inputTokens += turn.inputTokens
            outputTokens += turn.outputTokens
            let actions = turn.calls.flatMap(\.actions)
            guard turn.calls.allSatisfy({ $0.safetyChecks.isEmpty }) else {
                throw failure("The fixture requested a safety check.", turn: turn)
            }
            guard !actions.isEmpty, actions.allSatisfy({ $0.type == "screenshot" || $0.type == "click" }) else {
                throw failure("The model returned no click or requested an unexpected fixture action.", turn: turn)
            }
            let clicks = actions.filter { $0.type == "click" }
            if !clicks.isEmpty {
                guard clicks.count == 1, let action = clicks.first,
                      action.button == nil || action.button == "left",
                      let x = action.x, let y = action.y,
                      let point = try? frame.screenPoint(x: x, y: y),
                      (140..<340).contains(point.x), (130..<190).contains(point.y) else {
                    throw failure("The model did not return exactly one left click inside the test button.", turn: turn)
                }
                print("PASS: Luna returned a correctly grounded click on the generated test button.")
                print("No desktop input was executed. No real screen content was sent.")
                print("Requests: \(requestNumber). Tokens: \(inputTokens) input, \(outputTokens) output. Duration: \(String(format: "%.2f", Date().timeIntervalSince(start)))s.")
                return
            }
            // A native computer turn can begin by requesting only a screenshot.
            // Return the fixture for every call without capturing or changing the desktop.
            guard requestNumber < 3 else {
                throw failure("The model requested screenshots but no click within three requests.", turn: turn)
            }
            let outputs = turn.calls.map { (callID: $0.callID, frame: frame) }
            countRequest(&budget, at: usageURL, canPersist: &canPersistUsage)
            turn = try await client.continueTurn(responseID: turn.id, outputs: outputs)
        }
    }

    private static func loadUsage(at url: URL, canPersist: inout Bool) -> DemoBudget {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
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

    private static func failure(_ reason: String, turn: ModelTurn) -> ChosenError {
        let types = turn.calls.flatMap(\.actions).map(\.type).joined(separator: ", ")
        let message = turn.message.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        print("Fixture action types: \(types.isEmpty ? "(none)" : types)")
        print("Fixture model message: \(message.isEmpty ? "(none)" : String(message.prefix(280)))")
        return .api(reason)
    }
}
