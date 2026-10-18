import Foundation

/// A deliberately narrow, local admission check. Unknown or conversational
/// utterances never need a screenshot or a model request to be ignored.
public enum CommandIntent {
    public enum Control: Equatable { case stop, sleep }

    public static func control(_ text: String) -> Control? {
        guard !isQuoted(text) else { return nil }
        let words = requestWords(in: text)
        switch words.joined(separator: " ") {
        case "cancel", "cancel that", "cancel task", "cancel the task",
             "cancel action", "cancel the action", "cancel current action", "cancel the current action":
            return .stop
        case "stop", "stop now", "stop that", "stop task", "stop the task",
             "stop action", "stop the action", "stop current action", "stop the current action",
             "stop listening", "go to sleep", "sleep", "sleep mouse", "sleep chosen":
            return .sleep
        default:
            return nil
        }
    }

    public static func isClearCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !isQuoted(trimmed),
              control(text) == nil else { return false }
        let words = requestWords(in: text)
        guard !words.isEmpty else { return false }
        // Only the first operation decides admission. Later operations and typed
        // or searched text remain intact for the executor; never search for an
        // imperative buried inside conversation.
        if let comma = text.firstIndex(of: ",") {
            let clause = String(text[..<comma])
            if accepts(firstOperation(requestWords(in: clause)), original: clause) { return true }
        }
        let first = firstOperation(words)
        return accepts(first, original: text)
    }

    private static func accepts(_ words: [String], original: String) -> Bool {
        guard let verb = words.first else { return false }
        let rest = Array(words.dropFirst())
        if !["type", "search"].contains(verb), rest.contains(where: { ["tomorrow", "later", "tonight", "yesterday"].contains($0) }) { return false }
        switch verb {
        case "open", "launch":
            return isResourceTarget(dropLeading(rest, ["up", "the"]), original: original)
        case "start":
            return isKnownApp(dropLeading(rest, ["the"]))
        case "switch":
            guard rest.first == "to" else { return false }
            return isResourceTarget(dropLeading(Array(rest.dropFirst()), ["the"]), original: original)
        case "go":
            if rest.first == "search" { return accepts(rest, original: original) }
            if ["back", "forward", "fullscreen"].contains(rest.joined(separator: " ")) || rest == ["full", "screen"] { return true }
            guard rest.first == "to" else { return false }
            return isResourceTarget(dropLeading(Array(rest.dropFirst()), ["the"]), original: original)
        case "search":
            let target = dropLeading(rest, ["for"])
            guard hasOperand(target) else { return false }
            if rest.first == "for" { return true }
            return !isObviousStatement(target)
        case "click", "tap":
            let target = dropLeading(rest, ["on", "the"])
            return hasOperand(target) && !["with", "when", "if", "bait"].contains(target[0]) && !isObviousStatement(target)
        case "double", "right":
            guard rest.first == "click" else { return false }
            return accepts(["click"] + rest.dropFirst(), original: original)
        case "select":
            let target = dropLeading(rest, ["the"])
            return ["all", "everything", "that", "this"].contains(target.joined(separator: " ")) || isUITarget(target)
        case "type":
            guard hasOperand(rest) else { return false }
            if original.range(of: #"\btype\s+["“]"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
            return !["of", "when", "if", "faster", "slower", "better", "worse"].contains(rest[0]) && !isObviousStatement(rest)
        case "press", "hit":
            return isKeySequence(dropLeading(rest, ["the", "key"]))
        case "scroll":
            if rest.first == "to", ["comments", "the comments", "top", "the top", "bottom", "the bottom"].contains(rest.dropFirst().joined(separator: " ")) { return true }
            let target = dropLeading(rest, ["to", "the"])
            guard let direction = target.first, ["up", "down", "left", "right", "top", "bottom"].contains(direction) else { return false }
            return target.dropFirst().allSatisfy { distanceWords.contains($0) || Int($0) != nil }
        case "close", "quit":
            return isKnownApp(dropLeading(rest, ["the"])) || isUITarget(dropLeading(rest, ["the"]))
        case "play", "pause", "resume":
            return ["video", "the video", "this video", "current video", "the current video", "music", "the music", "playback"].contains(rest.joined(separator: " "))
        case "enter", "exit", "leave", "toggle":
            return ["fullscreen", "full screen"].contains(rest.joined(separator: " "))
        case "refresh", "reload":
            return rest.isEmpty || ["page", "the page", "this page", "tab", "the tab"].contains(rest.joined(separator: " "))
        case "back", "forward":
            return rest.isEmpty
        case "new":
            return rest == ["tab"] || rest == ["window"]
        case "next", "previous":
            return rest == ["tab"] || rest == ["page"]
        case "copy", "cut", "paste", "undo", "redo":
            return rest.isEmpty || ["that", "this", "selection", "the selection", "selected text", "the selected text"].contains(rest.joined(separator: " "))
        case "minimize", "maximize":
            return rest.isEmpty || isUITarget(dropLeading(rest, ["the"]))
        default:
            return false
        }
    }

    private static func hasOperand(_ words: [String]) -> Bool {
        !words.isEmpty && words.contains(where: { !["uh", "um", "erm", "uhh", "the", "an"].contains($0) })
    }

    private static func isObviousStatement(_ words: [String]) -> Bool {
        guard let first = words.first else { return true }
        // Question words are valid literal query/typing payloads. Copular noun
        // statements such as "search results are awful" remain conversation.
        if ["what", "why", "how", "who", "where", "when", "don't"].contains(first) { return false }
        return words.contains(where: { ["is", "are", "was", "were", "means", "seems"].contains($0) })
    }

    private static func isResourceTarget(_ words: [String], original: String) -> Bool {
        guard !words.isEmpty else { return false }
        if isKnownApp(words) || isUITarget(words) { return true }
        // URLs and explicit paths are concrete computer targets. Compare the
        // whole target so an address mentioned later cannot admit other speech.
        let pattern = #"(?:https?://|www\.)[^\s]+|(?:[a-z0-9-]+\.)+[a-z]{2,}(?:/[^\s]*)?|(?:~/|/)[^\s]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return regex.matches(in: original, range: NSRange(original.startIndex..., in: original)).contains {
            guard let range = Range($0.range, in: original) else { return false }
            return tokenize(String(original[range])) == words
        }
    }

    private static func isKnownApp(_ words: [String]) -> Bool {
        appNames.contains(words.joined(separator: " "))
    }

    private static func isUITarget(_ words: [String]) -> Bool {
        guard !words.isEmpty else { return false }
        if ["that", "this", "back", "forward", "top", "bottom"].contains(words.joined(separator: " ")) { return true }
        // A bounded UI noun phrase: possessives/ordinals and labels are allowed,
        // while statements or questions about an interface are not commands.
        guard words.count <= 10,
              words.contains(where: { uiNouns.contains($0) }),
              !words.contains(where: { ["is", "are", "was", "were", "because", "if", "would", "could", "should", "said", "asked", "don't", "not"].contains($0) }) else { return false }
        return true
    }

    private static func isKeySequence(_ words: [String]) -> Bool {
        guard !words.isEmpty, words.count <= 6 else { return false }
        return words.allSatisfy { keyNames.contains($0) || ($0.count == 1 && $0.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains)) }
    }

    private static func isQuoted(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["\"", "“", "'", "‘"].contains(where: { trimmed.hasPrefix($0) })
    }

    private static func requestWords(in text: String) -> [String] {
        var words = tokenize(text)
        // Strip only explicit ways of addressing the tool, not narrative phrases
        // such as "I was wondering" or "he said".
        for _ in 0..<4 {
            if words.first == "please" || words.first == "now" { words.removeFirst(); continue }
            if words.starts(with: ["hey", "mouse"]) || words.starts(with: ["hey", "chosen"]) { words.removeFirst(2); continue }
            if words.first == "mouse" || words.first == "chosen" { words.removeFirst(); continue }
            if words.count >= 2, ["can", "could", "would", "will"].contains(words[0]), words[1] == "you" { words.removeFirst(2); continue }
            break
        }
        if words.last == "please" { words.removeLast() }
        // Addressing at the end is a control convenience, not a target rewrite.
        if words.count >= 2, ["stop", "cancel"].contains(words[0]), ["mouse", "chosen"].contains(words.last!) { words.removeLast() }
        return words
    }

    private static func firstOperation(_ words: [String]) -> [String] {
        // Text/query payloads can contain "then", "and", or any command words.
        guard let first = words.first, !["type", "search"].contains(first) else { return words }
        for index in words.indices where index > 0 {
            if words[index] == "then" { return Array(words[..<index]) }
            // On-device speech punctuation is disabled. A complete first
            // operation followed directly by another verb is still a sequence.
            if operationVerbs.contains(words[index]), accepts(Array(words[..<index]), original: "") {
                return Array(words[..<index])
            }
            if words[index] == "and", index + 1 < words.count,
               words[index + 1] == "then" || operationVerbs.contains(words[index + 1]) {
                return Array(words[..<index])
            }
        }
        return words
    }

    private static func dropLeading(_ words: [String], _ prefixes: Set<String>) -> [String] {
        Array(words.drop(while: { prefixes.contains($0) }))
    }

    private static func tokenize(_ text: String) -> [String] {
        let pattern = #"[\p{L}\p{N}]+(?:['’][\p{L}\p{N}]+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            guard let range = Range($0.range, in: text) else { return nil }
            return String(text[range]).lowercased().replacingOccurrences(of: "’", with: "'")
        }
    }

    private static let appNames: Set<String> = [
        "chrome", "google chrome", "safari", "firefox", "edge", "microsoft edge", "brave", "arc", "opera",
        "youtube", "you tube", "finder", "terminal", "settings", "system settings", "mail", "messages", "notes",
        "music", "apple music", "spotify", "slack", "discord", "calendar", "calculator", "preview", "photos",
        "activity monitor", "app store", "vs code", "visual studio code", "xcode", "codex", "chatgpt", "chat gpt",
        "zoom", "facetime", "face time", "teams", "microsoft teams", "excel", "word", "powerpoint", "power point",
        "obs", "github", "notion", "figma", "reminders", "screenshot", "launchpad", "mouse", "chosen"
    ]
    private static let uiNouns: Set<String> = [
        "app", "application", "browser", "window", "windows", "tab", "tabs", "page", "pages", "website", "site",
        "link", "links", "button", "buttons", "menu", "menus", "dialog", "file", "files", "folder", "folders",
        "document", "documents", "video", "videos", "channel", "profile", "comment", "comments", "result", "results",
        "search", "settings", "desktop", "downloads", "text", "selection", "notification", "notifications"
    ]
    private static let keyNames: Set<String> = [
        "command", "cmd", "control", "ctrl", "option", "alt", "shift", "function", "fn", "enter", "return",
        "escape", "esc", "space", "spacebar", "tab", "delete", "backspace", "home", "end", "page", "up", "down",
        "left", "right", "arrow", "key", "plus", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"
    ]
    private static let distanceWords: Set<String> = ["a", "bit", "little", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "page", "pages", "line", "lines", "pixel", "pixels"]
    private static let operationVerbs: Set<String> = ["open", "launch", "start", "switch", "go", "search", "click", "tap", "double", "right", "select", "type", "press", "hit", "scroll", "close", "quit", "enter", "exit", "leave", "toggle", "refresh", "reload", "play", "pause", "resume", "back", "forward", "new", "next", "previous", "copy", "cut", "paste", "undo", "redo", "minimize", "maximize"]
}
