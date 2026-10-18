import Foundation

/// Continuous speech stays local. Only an explicit wake phrase at an utterance
/// boundary activates Mouse, and only clear computer commands cross this boundary.
public struct WakeSession {
    public enum Event: Equatable {
        case activated
        case partial(String)
        case command(String)
        case ignored
        case stopped
        case deactivated
    }

    public private(set) var isActive = false
    public private(set) var isExecuting = false
    public private(set) var pendingCommand = ""
    public private(set) var lastChangeAt: TimeInterval?

    private var previousWords: [String] = []
    private var ignoredWords: [String] = []
    private var carriedCommand = ""
    private var displayedPartial = ""

    public init() {}

    /// Replace a cumulative recognition stream without losing an unfinished
    /// utterance, activation, or a split wake/control phrase.
    public mutating func beginRecognition(preservingPending: Bool = false) {
        previousWords = []
        ignoredWords = []
        carriedCommand = preservingPending ? pendingCommand : ""
        if !preservingPending {
            pendingCommand = ""
            displayedPartial = ""
            lastChangeAt = nil
        }
    }

    @discardableResult
    public mutating func activate(at time: TimeInterval) -> [Event] {
        isActive = true
        clearUtterance()
        return [.activated]
    }

    @discardableResult
    public mutating func deactivate() -> [Event] {
        isActive = false
        isExecuting = false
        clearUtterance()
        return [.deactivated]
    }

    public mutating func setExecuting(_ executing: Bool, at time: TimeInterval) {
        let finishedExecution = isExecuting && !executing
        isExecuting = executing
        // Consume speech heard during the task before accepting a new command.
        if executing || (finishedExecution && CommandIntent.control(pendingCommand) == nil) { clearUtterance() }
    }

    public mutating func receive(_ transcript: String, at time: TimeInterval) -> [Event] {
        let tokens = Self.tokens(in: transcript)
        let words = tokens.map(\.word)
        guard words != previousWords else { return [] }
        previousWords = words
        let offset = min(ignoredWords.count, words.count)
        guard offset < tokens.count else { return [] }
        let suffix = (offset == 0 ? transcript : String(transcript[tokens[offset - 1].range.upperBound...]))
            .trimmingCharacters(in: Self.utteranceSeparators)
        var utterance = [carriedCommand, suffix].filter { !$0.isEmpty }.joined(separator: " ")
        var events: [Event] = []

        if !isExecuting {
            let utteranceTokens = Self.tokens(in: utterance)
            let isQuoted = ["\"", "“", "'", "‘"].contains(where: { utterance.hasPrefix($0) })
            if !isQuoted, let wakeEnd = Self.wakeEnd(in: utteranceTokens.map(\.word)) {
                let carriedCount = Self.tokens(in: carriedCommand).count
                let consumedCurrentWords = max(0, wakeEnd - carriedCount)
                ignoredWords = Array(words.prefix(offset + consumedCurrentWords))
                carriedCommand = ""
                utterance = String(utterance[utteranceTokens[wakeEnd - 1].range.upperBound...])
                    .trimmingCharacters(in: Self.utteranceSeparators)
                if !isActive {
                    isActive = true
                    events.append(.activated)
                }
            }
        }

        pendingCommand = utterance
        lastChangeAt = time
        // Controls wait for the acoustic endpoint as well: a partial "stop"
        // must not cancel a task before it becomes "stop by later".
        let visible = isActive && !isExecuting && CommandIntent.isClearCommand(utterance) ? utterance : ""
        if visible != displayedPartial {
            displayedPartial = visible
            events.append(.partial(visible))
        }
        return events
    }

    /// Called after the audio layer observes a full trailing silence window.
    public mutating func finishUtterance(at time: TimeInterval) -> [Event] {
        let utterance = pendingCommand
        let hadUtterance = !utterance.isEmpty
        clearUtterance()
        guard hadUtterance else { return [] }
        guard isActive || isExecuting else { return [] }
        if let control = CommandIntent.control(utterance) {
            switch control {
            case .sleep: return deactivate()
            case .stop:
                isExecuting = false
                return [.stopped]
            }
        }
        guard !isExecuting, CommandIntent.isClearCommand(utterance) else { return [.ignored] }
        return [.command(utterance)]
    }

    private mutating func clearUtterance() {
        pendingCommand = ""
        carriedCommand = ""
        ignoredWords = previousWords
        displayedPartial = ""
        lastChangeAt = nil
    }

    private static func wakeEnd(in words: [String]) -> Int? {
        let prefixCount = words.prefix(while: { ["okay", "ok", "please"].contains($0) }).count
        guard prefixCount <= 2, words.count >= prefixCount + 2,
              words[prefixCount] == "hey", ["mouse", "chosen"].contains(words[prefixCount + 1]) else { return nil }
        return prefixCount + 2
    }

    private static let utteranceSeparators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",:;.!?"))

    private static func tokens(in text: String) -> [(word: String, range: Range<String.Index>)] {
        let pattern = #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return (String(text[range]).lowercased(), range)
        }
    }
}
