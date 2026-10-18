import Foundation

/// The boundary between continuous, local wake-word monitoring and submitted
/// commands. Activation persists until an explicit sleep command; silence and
/// recognition-stream replacement never deactivate it.
public struct WakeSession {
    public enum Event: Equatable {
        case activated
        case partial(String)
        case command(String)
        /// Cancel the current action, while keeping the existing activation state.
        case stopped
        /// Return to local wake-word monitoring and cancel any current action.
        case deactivated
    }

    public private(set) var isActive = false
    public private(set) var isExecuting = false
    public private(set) var pendingCommand = ""
    public private(set) var lastChangeAt: TimeInterval?

    private var previousWords: [String] = []
    private var ignoredWords: [String] = []
    private var carriedCommand = ""
    // A partial "stop" cancels immediately. Keep its stream until the acoustic
    // boundary so a subsequent partial "stop listening" can still put us to sleep.
    private var interruptionOffset: Int?
    private var carriedInterruptionWords: [String] = []

    public init() {}

    /// Call when replacing a cumulative recognition stream, never for every partial.
    public mutating func beginRecognition(preservingPending: Bool = false) {
        if preservingPending, let interruptionOffset {
            carriedInterruptionWords += previousWords.dropFirst(interruptionOffset)
            self.interruptionOffset = 0
        } else {
            interruptionOffset = nil
            carriedInterruptionWords = []
        }
        previousWords = []
        ignoredWords = []
        carriedCommand = preservingPending ? pendingCommand : ""
        if !preservingPending { pendingCommand = "" }
        if pendingCommand.isEmpty && interruptionOffset == nil { lastChangeAt = nil }
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

    /// Execution pauses command submission, but never disables voice interruption.
    public mutating func setExecuting(_ executing: Bool, at time: TimeInterval) {
        let finishedExecution = isExecuting && !executing
        isExecuting = executing
        // Speech observed while actions were running must not be prepended to
        // the next command in the same cumulative recognition stream. A voice
        // interruption has already set isExecuting to false, so its partial
        // "stop" remains available to finish as "stop listening".
        if executing || finishedExecution { clearUtterance() }
    }

    public mutating func receive(_ transcript: String, at time: TimeInterval) -> [Event] {
        var events: [Event] = []
        let tokens = Self.tokens(in: transcript)
        let words = tokens.map(\.word)
        guard words != previousWords else { return events }
        previousWords = words

        if let interruptionOffset {
            let interruptedPhrase = carriedInterruptionWords + Array(words.dropFirst(interruptionOffset))
            if Self.isDeactivation(interruptedPhrase) { return deactivate() }
            // Do not submit the remainder of the cancelled utterance as a new task.
            ignoredWords = words
            lastChangeAt = time
            return []
        }

        // Recognition revises partials. Keep the consumed prefix behind the boundary,
        // even when spelling or punctuation in that prefix is revised later.
        let offset = min(ignoredWords.count, words.count)
        let available = Array(words.dropFirst(offset))
        guard !available.isEmpty else { return events }

        if isExecuting {
            // Commands aren't accepted during execution, so interruption can occur
            // after other recognized background words without repeating the wake phrase.
            if available.indices.contains(where: { Self.isDeactivation(Array(available[$0...])) }) {
                return deactivate()
            }
            if let index = available.firstIndex(where: { $0 == "stop" || $0 == "cancel" }) {
                return interrupt(from: offset + index, at: time)
            }
            return events
        }

        var commandOffset = offset
        if !isActive {
            guard let wake = Self.wakeIndex(in: available) else { return events }
            commandOffset = offset + wake + 2
            ignoredWords = Array(words.prefix(commandOffset))
            isActive = true
            events.append(.activated)
        } else if let wake = Self.wakeIndex(in: available), wake == 0 {
            // Repeating the wake phrase while active is harmless.
            commandOffset = offset + 2
            ignoredWords = Array(words.prefix(commandOffset))
        }

        let commandWords = Array(words.dropFirst(commandOffset))
        let carriedWords = Self.tokens(in: carriedCommand).map(\.word)
        if Self.isDeactivation(commandWords) || Self.isDeactivation(carriedWords + commandWords) {
            return events + deactivate()
        }
        if Self.isInterruption(commandWords) {
            return events + interrupt(from: commandOffset, at: time)
        }
        let suffix: String
        if commandOffset < tokens.count {
            suffix = String(transcript[tokens[commandOffset].range.lowerBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            suffix = ""
        }
        let command = [carriedCommand, suffix].filter { !$0.isEmpty }.joined(separator: " ")
        guard command != pendingCommand else { return events }
        pendingCommand = command
        lastChangeAt = time
        events.append(.partial(command))
        return events
    }

    /// The audio layer calls this after actual silence, not after seeing the wake phrase.
    public mutating func finishUtterance(at time: TimeInterval) -> [Event] {
        if interruptionOffset != nil {
            clearUtterance()
            return []
        }
        guard isActive, !isExecuting, !pendingCommand.isEmpty else { return [] }
        let command = pendingCommand
        clearUtterance()
        return [.command(command)]
    }

    private mutating func clearUtterance() {
        pendingCommand = ""
        carriedCommand = ""
        ignoredWords = previousWords
        interruptionOffset = nil
        carriedInterruptionWords = []
        lastChangeAt = nil
    }

    private mutating func interrupt(from offset: Int, at time: TimeInterval) -> [Event] {
        isExecuting = false
        clearUtterance()
        interruptionOffset = offset
        lastChangeAt = time
        return [.stopped]
    }

    private static func wakeIndex(in words: [String]) -> Int? {
        guard words.count >= 2 else { return nil }
        return (0..<(words.count - 1)).first {
            words[$0] == "hey" && ["mouse", "chosen"].contains(words[$0 + 1])
        }
    }

    private static func isDeactivation(_ words: [String]) -> Bool {
        let meaningful = Array(words.drop(while: { ["please", "mouse", "chosen"].contains($0) }))
        return meaningful.starts(with: ["stop", "listening"])
            || meaningful.starts(with: ["go", "to", "sleep"])
            || meaningful.starts(with: ["sleep", "mouse"])
            || meaningful.starts(with: ["sleep", "chosen"])
    }

    private static func isInterruption(_ words: [String]) -> Bool {
        let meaningful = words.drop(while: { ["please", "mouse", "chosen"].contains($0) })
        return meaningful.first == "stop" || meaningful.first == "cancel"
    }

    private static func tokens(in text: String) -> [(word: String, range: Range<String.Index>)] {
        let pattern = #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return (String(text[range]).lowercased(), range)
        }
    }
}
