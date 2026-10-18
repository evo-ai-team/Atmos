import AppKit
import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers
#if SWIFT_PACKAGE
import ChosenCore
#endif

/// All coordinates use Quartz's global, top-left origin, including displays above
/// or to the left of the main display. A command stays on its initial display.
@MainActor
final class NativeComputer {
    private var selectedDisplayID: CGDirectDisplayID?
    private let eventSource = CGEventSource(stateID: .privateState)
    private let postEvent: (CGEvent) -> Void
    private let checkAccessibility: () -> Bool

    var screenRecordingGranted: Bool { CGPreflightScreenCaptureAccess() }
    var accessibilityGranted: Bool { checkAccessibility() }

    // Injection lets offline checks inspect the actual event sequence without
    // posting to the desktop or requiring accessibility permission.
    init(eventPoster: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
         accessibilityCheck: @escaping () -> Bool = { AXIsProcessTrusted() && CGPreflightPostEventAccess() }) {
        postEvent = eventPoster
        checkAccessibility = accessibilityCheck
        // Leave physical input available so the user can interrupt a command.
        eventSource?.localEventsSuppressionInterval = 0
    }

    @discardableResult
    func requestScreenRecordingPermission() -> Bool { CGRequestScreenCaptureAccess() }

    @discardableResult
    func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
        return accessibilityGranted
    }

    /// Call once at the beginning of a command, before hiding the command panel.
    func resetDisplay() {
        var display = CGMainDisplayID()
        var count: UInt32 = 0
        let point = CGEvent(source: nil)?.location ?? .zero
        if CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0 {
            selectedDisplayID = display
        } else {
            selectedDisplayID = CGMainDisplayID()
        }
    }

    func capture() async throws -> ScreenshotFrame {
        try Task.checkCancellation()
        guard screenRecordingGranted else {
            throw ChosenError.permission("Allow Chosen in System Settings → Privacy & Security → Screen & System Audio Recording, then retry.")
        }
        if selectedDisplayID == nil { resetDisplay() }
        let displayID = selectedDisplayID ?? CGMainDisplayID()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == displayID }), CGDisplayIsActive(displayID) != 0 else {
            throw ChosenError.configuration("The selected display is no longer available. Start a new command on a connected display.")
        }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else {
            throw ChosenError.configuration("The selected display has invalid dimensions.")
        }
        let ownApplications = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ownApplications, exceptingWindows: [])
        filter.includeMenuBar = true
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int(min(bounds.width, 1_600).rounded()))
        configuration.height = max(1, Int((Double(configuration.width) * bounds.height / bounds.width).rounded()))
        configuration.captureResolution = .nominal
        configuration.scalesToFit = true
        configuration.showsCursor = true
        configuration.capturesAudio = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.colorSpaceName = CGColorSpace.sRGB

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        try Task.checkCancellation()
        // Do not return a stale mapping if a monitor was rearranged during capture.
        guard CGDisplayIsActive(displayID) != 0, CGDisplayBounds(displayID) == bounds else {
            throw ChosenError.configuration("The display arrangement changed during capture. Retry the command.")
        }
        return ScreenshotFrame(data: try Self.encodeJPEG(image), width: image.width, height: image.height,
                               originX: bounds.minX, originY: bounds.minY,
                               pointWidth: bounds.width, pointHeight: bounds.height, displayID: displayID)
    }

    /// Performs no input or permission prompts. The controller can preflight an
    /// entire batch before allowing the first action to affect the desktop.
    func validateAction(_ action: ComputerAction, frame: ScreenshotFrame) throws {
        _ = try validate(action, frame: frame)
    }

    static func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ChosenError.configuration("Could not create the screenshot encoder.")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ChosenError.configuration("Could not encode the screenshot.")
        }
        return data as Data
    }

    func execute(_ action: ComputerAction, frame: ScreenshotFrame) async throws {
        try Task.checkCancellation()
        // Validate the complete action before generating any input, including all
        // drag points and every key in a shortcut.
        let validated = try validate(action, frame: frame)
        switch validated {
        case .screenshot:
            return // The controller captures the result after the action batch.
        case .wait:
            try await pause(milliseconds: 750)
            return
        default:
            guard accessibilityGranted else {
                throw ChosenError.permission("Allow Chosen in System Settings → Privacy & Security → Accessibility, then retry.")
            }
        }
        guard eventSource != nil else { throw ChosenError.configuration("Could not create the native input event source.") }
        switch validated {
        case let .click(point, button, count, modifiers):
            try await withModifiers(modifiers) { flags in
                try await self.click(point, button: button, count: count, flags: flags)
            }
        case let .move(point, modifiers):
            try await withModifiers(modifiers) { flags in
                let event = try self.mouseEvent(.mouseMoved, point: point, button: .left, flags: flags)
                self.postEvent(event)
            }
        case let .scroll(point, x, y, modifiers):
            try await withModifiers(modifiers) { flags in
                let move = try self.mouseEvent(.mouseMoved, point: point, button: .left, flags: flags)
                guard let scroll = CGEvent(scrollWheelEvent2Source: self.eventSource, units: .pixel, wheelCount: 2, wheel1: -y, wheel2: -x, wheel3: 0) else {
                    throw ChosenError.configuration("Could not create a scroll event.")
                }
                scroll.location = point
                scroll.flags = flags
                self.postEvent(move)
                try Task.checkCancellation()
                self.postEvent(scroll)
            }
        case let .drag(points, modifiers):
            try await withModifiers(modifiers) { flags in
                try await self.drag(points, flags: flags)
            }
        case let .type(tokens):
            for token in tokens {
                try Task.checkCancellation()
                switch token {
                case let .text(units): try postUnicode(units)
                case let .key(code): try postKeyPair(code)
                }
                try await pause(milliseconds: 8)
            }
        case let .keypress(keys):
            try await press(keys)
        case .screenshot, .wait:
            break
        }
    }

    private enum ValidatedAction {
        case click(CGPoint, MouseButton, Int, [Key]), move(CGPoint, [Key]), scroll(CGPoint, Int32, Int32, [Key])
        case drag([CGPoint], [Key]), type([TypingToken]), keypress([Key]), wait, screenshot
    }
    private enum TypingToken { case text([UniChar]), key(CGKeyCode) }
    private struct MouseButton {
        let button: CGMouseButton
        let down: CGEventType
        let up: CGEventType
        static let left = MouseButton(button: .left, down: .leftMouseDown, up: .leftMouseUp)
    }
    private struct Key {
        let code: CGKeyCode
        var modifier: CGEventFlags = []
        var implicitFlags: CGEventFlags = []
    }

    private func validate(_ action: ComputerAction, frame: ScreenshotFrame) throws -> ValidatedAction {
        switch action.type.lowercased() {
        case "click", "double_click":
            let point = try actionPoint(action, frame: frame)
            let button = try mouseButton(action.button ?? "left")
            return .click(point, button, action.type.lowercased() == "double_click" ? 2 : 1, try mouseModifiers(action.keys))
        case "move": return .move(try actionPoint(action, frame: frame), try mouseModifiers(action.keys))
        case "scroll":
            let point = try actionPoint(action, frame: frame)
            guard let x = action.scrollX, let y = action.scrollY, x.isFinite, y.isFinite,
                  abs(x) <= 100_000, abs(y) <= 100_000 else {
                throw ChosenError.invalidAction("A scroll requires finite scroll_x and scroll_y values within 100,000 pixels.")
            }
            return .scroll(point, Int32(x.rounded()), Int32(y.rounded()), try mouseModifiers(action.keys))
        case "drag":
            guard let path = action.path, (2...1_000).contains(path.count) else {
                throw ChosenError.invalidAction("A drag requires a path containing 2 to 1,000 points.")
            }
            try validateDisplay(frame)
            let points = try path.map { try screenPoint(x: $0.x, y: $0.y, frame: frame) }
            guard action.button == nil || action.button?.lowercased() == "left" else {
                throw ChosenError.invalidAction("A drag currently supports only the left mouse button.")
            }
            return .drag(points, try mouseModifiers(action.keys))
        case "type":
            try rejectExtraKeys(action)
            guard let text = action.text, text.utf16.count <= 100_000 else {
                throw ChosenError.invalidAction("A typing action requires text of at most 100,000 UTF-16 characters.")
            }
            return .type(try typingTokens(text))
        case "keypress":
            guard let names = action.keys, !names.isEmpty, names.count <= 5 else {
                throw ChosenError.invalidAction("A keypress requires one key and up to four modifiers.")
            }
            let keys = try names.map(key)
            guard Set(keys.map(\.code)).count == keys.count, keys.filter({ $0.modifier.isEmpty }).count <= 1 else {
                throw ChosenError.invalidAction("A shortcut can contain each modifier once and at most one non-modifier key.")
            }
            return .keypress(keys.sorted { !$0.modifier.isEmpty && $1.modifier.isEmpty })
        case "wait": try rejectExtraKeys(action); return .wait
        case "screenshot": try rejectExtraKeys(action); return .screenshot
        default: throw ChosenError.invalidAction("Unsupported computer action: \(action.type).")
        }
    }

    private func mouseModifiers(_ names: [String]?) throws -> [Key] {
        guard let names else { return [] }
        guard names.count <= 4 else {
            throw ChosenError.invalidAction("A mouse action supports at most four modifier keys.")
        }
        let modifiers = try names.map(key)
        guard modifiers.allSatisfy({ !$0.modifier.isEmpty }), Set(modifiers.map(\.code)).count == modifiers.count else {
            throw ChosenError.invalidAction("Mouse action keys must be distinct Command, Control, Option, or Shift modifiers.")
        }
        return modifiers
    }

    private func rejectExtraKeys(_ action: ComputerAction) throws {
        guard action.keys?.isEmpty != false else {
            throw ChosenError.invalidAction("The \(action.type) action does not support held keys.")
        }
    }

    private func validateDisplay(_ frame: ScreenshotFrame) throws {
        guard frame.width > 0, frame.height > 0, frame.originX.isFinite, frame.originY.isFinite,
              frame.pointWidth.isFinite, frame.pointHeight.isFinite, frame.pointWidth > 0, frame.pointHeight > 0,
              frame.displayID != 0, CGDisplayIsActive(frame.displayID) != 0 else {
            throw ChosenError.invalidAction("The screenshot has no valid connected display.")
        }
        let captured = CGRect(x: frame.originX, y: frame.originY, width: frame.pointWidth, height: frame.pointHeight)
        guard CGDisplayBounds(frame.displayID) == captured else {
            throw ChosenError.invalidAction("The display arrangement changed. Capture a new screenshot before acting.")
        }
    }

    private func actionPoint(_ action: ComputerAction, frame: ScreenshotFrame) throws -> CGPoint {
        guard let x = action.x, let y = action.y else {
            throw ChosenError.invalidAction("This action requires both x and y coordinates.")
        }
        try validateDisplay(frame)
        return try screenPoint(x: x, y: y, frame: frame)
    }

    private func screenPoint(x: Double, y: Double, frame: ScreenshotFrame) throws -> CGPoint {
        let point = try frame.screenPoint(x: x, y: y)
        guard point.x.isFinite, point.y.isFinite else { throw ChosenError.invalidAction("Invalid screen coordinates.") }
        return CGPoint(x: point.x, y: point.y)
    }

    private func mouseButton(_ name: String) throws -> MouseButton {
        switch name.lowercased() {
        case "left": return .left
        case "right": return MouseButton(button: .right, down: .rightMouseDown, up: .rightMouseUp)
        case "middle", "wheel": return MouseButton(button: .center, down: .otherMouseDown, up: .otherMouseUp)
        case "back": return MouseButton(button: CGMouseButton(rawValue: 3)!, down: .otherMouseDown, up: .otherMouseUp)
        case "forward": return MouseButton(button: CGMouseButton(rawValue: 4)!, down: .otherMouseDown, up: .otherMouseUp)
        default: throw ChosenError.invalidAction("Unsupported mouse button: \(name).")
        }
    }

    private func mouseEvent(_ type: CGEventType, point: CGPoint, button: CGMouseButton, flags: CGEventFlags = []) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw ChosenError.configuration("Could not create a mouse event.")
        }
        event.flags = flags
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        return event
    }

    private func click(_ point: CGPoint, button: MouseButton, count: Int, flags: CGEventFlags) async throws {
        for index in 1...count {
            try Task.checkCancellation()
            let down = try mouseEvent(button.down, point: point, button: button.button, flags: flags)
            let up = try mouseEvent(button.up, point: point, button: button.button, flags: flags)
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            postEvent(down)
            // The matching release is posted even if Stop cancels this sleep.
            do { try await pause(milliseconds: 35) } catch { postEvent(up); throw error }
            postEvent(up)
            if index < count { try await pause(milliseconds: 65) }
        }
    }

    private func drag(_ points: [CGPoint], flags: CGEventFlags) async throws {
        guard let first = points.first else { throw ChosenError.invalidAction("The drag path is empty.") }
        let down = try mouseEvent(.leftMouseDown, point: first, button: .left, flags: flags)
        let up = try mouseEvent(.leftMouseUp, point: first, button: .left, flags: flags)
        // Allocate every event before pressing, so failure cannot strand a button.
        let moves = try points.dropFirst().map { try mouseEvent(.leftMouseDragged, point: $0, button: .left, flags: flags) }
        postEvent(down)
        defer { postEvent(up) }
        try await pause(milliseconds: 50)
        for move in moves {
            try Task.checkCancellation()
            up.location = move.location
            postEvent(move)
            try await pause(milliseconds: 20)
        }
    }

    private func withModifiers(_ modifiers: [Key], operation: (CGEventFlags) async throws -> Void) async throws {
        // Allocate both directions before pressing any modifier. Unwind mouse
        // button state inside the operation before releasing these held keys.
        let downs = try modifiers.map { try keyboardEvent($0.code, down: true) }
        let ups = try modifiers.map { try keyboardEvent($0.code, down: false) }
        var flags = CGEventFlags()
        var postedCount = 0
        defer {
            for index in (0..<postedCount).reversed() {
                flags.subtract(modifiers[index].modifier)
                ups[index].type = .flagsChanged
                ups[index].flags = flags
                postEvent(ups[index])
            }
        }
        for (index, modifier) in modifiers.enumerated() {
            try Task.checkCancellation()
            flags.formUnion(modifier.modifier)
            downs[index].type = .flagsChanged
            downs[index].flags = flags
            postEvent(downs[index])
            postedCount += 1
        }
        try Task.checkCancellation()
        try await operation(flags)
        try Task.checkCancellation()
    }

    private func keyboardEvent(_ code: CGKeyCode, down: Bool) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else {
            throw ChosenError.configuration("Could not create a keyboard event.")
        }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        return event
    }

    private func postKeyPair(_ code: CGKeyCode) throws {
        let down = try keyboardEvent(code, down: true)
        let up = try keyboardEvent(code, down: false)
        postEvent(down)
        postEvent(up)
    }

    private func postUnicode(_ units: [UniChar]) throws {
        let down = try keyboardEvent(0, down: true)
        let up = try keyboardEvent(0, down: false)
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        postEvent(down)
        postEvent(up)
    }

    private func press(_ requestedKeys: [Key]) async throws {
        var keys = requestedKeys
        // Symbols such as '?' need a real, balanced Shift press as well as flags.
        if keys.contains(where: { $0.implicitFlags.contains(.maskShift) }),
           !keys.contains(where: { $0.modifier.contains(.maskShift) }) {
            keys.insert(Key(code: 56, modifier: .maskShift), at: 0)
        }
        let downs = try keys.map { try keyboardEvent($0.code, down: true) }
        let ups = try keys.map { try keyboardEvent($0.code, down: false) }
        var flags = CGEventFlags()
        var postedCount = 0
        defer {
            for index in (0..<postedCount).reversed() {
                flags.subtract(keys[index].modifier)
                ups[index].flags = flags
                if !keys[index].modifier.isEmpty { ups[index].type = .flagsChanged }
                postEvent(ups[index])
            }
        }
        for (index, key) in keys.enumerated() {
            try Task.checkCancellation()
            flags.formUnion(key.modifier)
            downs[index].flags = flags
            if !key.modifier.isEmpty { downs[index].type = .flagsChanged }
            postEvent(downs[index])
            postedCount += 1
        }
        try await pause(milliseconds: 40)
    }

    private func typingTokens(_ text: String) throws -> [TypingToken] {
        var result: [TypingToken] = []
        var buffer: [UniChar] = []
        func flush() { if !buffer.isEmpty { result.append(.text(buffer)); buffer.removeAll(keepingCapacity: true) } }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" { flush(); result.append(.key(36)); continue }
            if scalar == "\t" { flush(); result.append(.key(48)); continue }
            guard scalar.value >= 0x20, !(0x7F...0x9F).contains(scalar.value) else {
                throw ChosenError.invalidAction("Typed text contains an unsupported control character.")
            }
            let units = Array(String(scalar).utf16)
            if buffer.count + units.count > 20 { flush() }
            buffer.append(contentsOf: units)
        }
        flush()
        return result
    }

    private func key(_ name: String) throws -> Key {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let modifiers: [String: (CGKeyCode, CGEventFlags)] = [
            "cmd": (55, .maskCommand), "command": (55, .maskCommand), "meta": (55, .maskCommand), "super": (55, .maskCommand),
            "ctrl": (59, .maskControl), "control": (59, .maskControl),
            "alt": (58, .maskAlternate), "option": (58, .maskAlternate),
            "shift": (56, .maskShift)
        ]
        if let (code, flag) = modifiers[value] { return Key(code: code, modifier: flag) }
        let special: [String: CGKeyCode] = [
            "enter": 36, "return": 36, "tab": 48, "space": 49, "spacebar": 49,
            "backspace": 51, "delete": 117, "del": 117, "forwarddelete": 117,
            "esc": 53, "escape": 53, "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
            "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124,
            "down": 125, "arrowdown": 125, "up": 126, "arrowup": 126,
            "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
            "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
            "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90
        ]
        if let code = special[value] { return Key(code: code) }
        if name == " " { return Key(code: 49) }
        guard value.count == 1 else { throw ChosenError.invalidAction("Unsupported key: \(name).") }
        // Resolve printable shortcut keys against the current ASCII-capable layout
        // instead of assuming the user's keyboard has US physical key positions.
        if let found = printableKey(value) { return found }
        throw ChosenError.invalidAction("The current keyboard layout has no supported key for \(name).")
    }

    private func printableKey(_ character: String) -> Key? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(rawData).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        for shifted in [false, true] {
            for code in CGKeyCode(0)...CGKeyCode(127) {
                var deadKeyState: UInt32 = 0
                var length = 0
                var output = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), shifted ? UInt32(shiftKey >> 8) : 0,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeyState, output.count, &length, &output)
                if status == noErr, length > 0, String(utf16CodeUnits: output, count: length) == character {
                    return Key(code: code, implicitFlags: shifted ? .maskShift : [])
                }
            }
        }
        return nil
    }

    private func pause(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
