import Foundation

/// The privacy boundary between continuous, local transcription and submitted commands.
/// Time is supplied by the caller so timeout behavior is deterministic and testable.
public struct WakeSession {
    public enum Event: Equatable {
        case activated
        case partial(String)
        case command(String)
        case stopped
        case expired
    }

    public let followUpDuration: TimeInterval
    public private(set) var isActive = false
    public private(set) var isExecuting = false
    public private(set) var pendingCommand = ""
    public private(set) var lastChangeAt: TimeInterval?
    public private(set) var expiresAt: TimeInterval?

    private var previousWords: [String] = []
    private var ignoredWords: [String] = []
    private var carriedCommand = ""

    public init(followUpDuration: TimeInterval = 20) {
        self.followUpDuration = followUpDuration
    }

    /// Call when replacing a cumulative recognition stream, never for every partial.
    public mutating func beginRecognition(preservingPending: Bool = false) {
        previousWords = []
        ignoredWords = []
        carriedCommand = preservingPending ? pendingCommand : ""
        if !preservingPending {
            pendingCommand = ""
            lastChangeAt = nil
        }
    }

    @discardableResult
    public mutating func activate(at time: TimeInterval) -> [Event] {
        isActive = true
        expiresAt = time + followUpDuration
        pendingCommand = ""
        carriedCommand = ""
        ignoredWords = previousWords
        lastChangeAt = nil
        return [.activated]
    }

    /// Execution suspends the follow-up timeout, but never disables interruption.
    public mutating func setExecuting(_ executing: Bool, at time: TimeInterval) {
        isExecuting = executing
        if executing {
            pendingCommand = ""
            carriedCommand = ""
            ignoredWords = previousWords
            lastChangeAt = nil
        } else if isActive {
            expiresAt = time + followUpDuration
        }
    }

    public mutating func receive(_ transcript: String, at time: TimeInterval) -> [Event] {
        var events = expire(at: time)
        let tokens = Self.tokens(in: transcript)
        let words = tokens.map(\.word)
        guard words != previousWords else { return events }
        previousWords = words

        // Recognition revises partials. Keep the consumed prefix behind the boundary,
        // even when spelling or punctuation in that prefix is revised later.
        let offset = min(ignoredWords.count, words.count)
        let available = Array(words.dropFirst(offset))
        guard !available.isEmpty else { return events }

        if isExecuting {
            if available.contains("stop") || available.contains("cancel") {
                events += interrupt()
            }
            return events
        }

        var commandOffset = offset
        if !isActive {
            guard let wake = Self.wakeIndex(in: available) else { return events }
            commandOffset = offset + wake + 2
            ignoredWords = Array(words.prefix(commandOffset))
            isActive = true
            expiresAt = time + followUpDuration
            events.append(.activated)
        } else if let wake = Self.wakeIndex(in: available), wake == 0 {
            // Repeating the wake phrase during the follow-up window is harmless.
            commandOffset = offset + 2
            ignoredWords = Array(words.prefix(commandOffset))
        }

        let commandWords = Array(words.dropFirst(commandOffset))
        if Self.isInterruption(commandWords) {
            events += interrupt()
            return events
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
        expiresAt = time + followUpDuration
        events.append(.partial(command))
        return events
    }

    /// The audio layer calls this after actual silence, not after seeing the wake phrase.
    public mutating func finishUtterance(at time: TimeInterval) -> [Event] {
        let events = expire(at: time)
        guard isActive, !isExecuting, !pendingCommand.isEmpty else { return events }
        let command = pendingCommand
        pendingCommand = ""
        carriedCommand = ""
        ignoredWords = previousWords
        lastChangeAt = nil
        expiresAt = time + followUpDuration
        return events + [.command(command)]
    }

    public mutating func expire(at time: TimeInterval) -> [Event] {
        guard isActive, !isExecuting, let expiresAt, time >= expiresAt else { return [] }
        isActive = false
        self.expiresAt = nil
        pendingCommand = ""
        carriedCommand = ""
        ignoredWords = previousWords
        lastChangeAt = nil
        return [.expired]
    }

    private mutating func interrupt() -> [Event] {
        isActive = false
        isExecuting = false
        expiresAt = nil
        pendingCommand = ""
        carriedCommand = ""
        ignoredWords = previousWords
        lastChangeAt = nil
        return [.stopped]
    }

    private static func wakeIndex(in words: [String]) -> Int? {
        guard words.count >= 2 else { return nil }
        return (0..<(words.count - 1)).first { words[$0] == "hey" && words[$0 + 1] == "chosen" }
    }

    private static func isInterruption(_ words: [String]) -> Bool {
        let meaningful = words.filter { !["please", "chosen"].contains($0) }
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
