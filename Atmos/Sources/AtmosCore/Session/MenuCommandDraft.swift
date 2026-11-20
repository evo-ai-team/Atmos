import Foundation

/// A single editor buffer. Apple revises the same span until it finalizes,
/// while edits on either side of the spoken span belong to the user.
public struct MenuCommandDraft: Equatable {
    private var before = ""
    private var spoken = ""
    private var after = ""
    private var autoSpace = true

    public init() {}

    public var text: String {
        guard !spoken.isEmpty else { return before + after }
        let space = autoSpace && !before.isEmpty && before.last?.isWhitespace != true ? " " : ""
        return before + space + spoken + after
    }

    /// Replacing any live words starts a fresh audio boundary. This prevents
    /// late corrections of those words from undoing the user's edit.
    @discardableResult
    public mutating func edit(_ newText: String) -> Bool {
        guard text != newText else { return false }
        let speechAndTail = spoken + after
        let throughSpeech = String(text.dropLast(after.count))
        if !spoken.isEmpty, newText.hasPrefix(throughSpeech) {
            after = String(newText.dropFirst(throughSpeech.count))
            return false
        }
        if !spoken.isEmpty, newText.hasSuffix(speechAndTail) {
            before = String(newText.dropLast(speechAndTail.count))
            autoSpace = false
            return false
        }
        let replacedLiveWords = !spoken.isEmpty
        before = newText
        spoken = ""
        after = ""
        autoSpace = true
        return replacedLiveWords
    }

    public mutating func preview(_ words: String) {
        spoken = words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func finalize(_ words: String) {
        preview(words)
        endDictation()
    }

    public mutating func endDictation() {
        before = text
        spoken = ""
        after = ""
        autoSpace = true
    }

    public mutating func take() -> String? {
        let command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return nil }
        self = Self()
        return command
    }
}
