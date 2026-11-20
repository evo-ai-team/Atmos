import AppKit
import ApplicationServices
import CoreGraphics
#if SWIFT_PACKAGE
import AtmosCore
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
        // Leave physical input available while Atmos posts its own events.
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

    func capture(timing: PipelineTiming? = nil) async throws -> ScreenshotFrame {
        try Task.checkCancellation()
        guard screenRecordingGranted else {
            throw AtmosError.permission("Allow Atmos in System Settings → Privacy & Security → Screen & System Audio Recording, then retry.")
        }
        if selectedDisplayID == nil { resetDisplay() }
        let displayID = selectedDisplayID ?? CGMainDisplayID()
        return try await DisplayCapture.capture(displayID: displayID, timing: timing)
    }

    /// Performs no input or permission prompts. The controller can preflight an
    /// entire batch before allowing the first action to affect the desktop.
    func validateAction(_ action: ComputerAction, frame: ScreenshotFrame) throws {
        _ = try validate(action, frame: frame)
    }

    func validateFrame(_ frame: ScreenshotFrame) throws { try validateDisplay(frame) }

    static func encodeJPEG(_ image: CGImage) throws -> Data {
        try DisplayCapture.encodeJPEG(image)
    }

    func execute(_ action: ComputerAction, frame: ScreenshotFrame, timing: PipelineTiming? = nil) async throws {
        var stage = timing?.begin("Generated action validation")
        var stageOutcome: PipelineTiming.Outcome = .failed
        defer { timing?.end(stage, outcome: Task.isCancelled ? .cancelled : stageOutcome) }
        try Task.checkCancellation()
        // Validate the complete action before generating any input, including all
        // drag points and every key in a shortcut.
        let validated = try validate(action, frame: frame)
        timing?.end(stage, outcome: .succeeded)
        stage = timing?.begin("Generated action dispatch (\(action.type.lowercased()))")
        switch validated {
        case .screenshot:
            stageOutcome = .succeeded
            return // The controller captures the result after the action batch.
        case .wait:
            try await pause(milliseconds: 750)
            stageOutcome = .succeeded
            return
        default:
            guard accessibilityGranted else {
                throw AtmosError.permission("Allow Atmos in System Settings → Privacy & Security → Accessibility, then retry.")
            }
        }
        guard eventSource != nil else { throw AtmosError.configuration("Could not create the native input event source.") }
        switch validated {
        case let .click(point, button, count, modifiers):
            try await withModifiers(modifiers, timing: timing) { flags in
                try await self.click(point, button: button, count: count, flags: flags, timing: timing)
            }
        case let .move(point, modifiers):
            try await withModifiers(modifiers, timing: timing) { flags in
                let event = try self.mouseEvent(.mouseMoved, point: point, button: .left, flags: flags)
                self.postInput(event, timing: timing)
            }
        case let .scroll(point, x, y, modifiers):
            try await withModifiers(modifiers, timing: timing) { flags in
                let move = try self.mouseEvent(.mouseMoved, point: point, button: .left, flags: flags)
                guard let scroll = CGEvent(scrollWheelEvent2Source: self.eventSource, units: .pixel, wheelCount: 2, wheel1: -y, wheel2: -x, wheel3: 0) else {
                    throw AtmosError.configuration("Could not create a scroll event.")
                }
                scroll.location = point
                scroll.flags = flags
                self.postInput(move, timing: timing)
                try Task.checkCancellation()
                self.postInput(scroll, timing: timing)
            }
        case let .drag(points, modifiers):
            try await withModifiers(modifiers, timing: timing) { flags in
                try await self.drag(points, flags: flags, timing: timing)
            }
        case let .type(tokens):
            for token in tokens {
                try Task.checkCancellation()
                switch token {
                case let .text(units): try postUnicode(units, timing: timing)
                case let .key(code): try postKeyPair(code, timing: timing)
                }
                try await pause(milliseconds: 8)
            }
        case let .keypress(keys):
            try await press(keys, timing: timing)
        case .screenshot, .wait:
            break
        }
        stageOutcome = .succeeded
    }

    private enum ValidatedAction {
        case click(CGPoint, MouseButton, Int, [Key]), move(CGPoint, [Key]), scroll(CGPoint, Int32, Int32, [Key])
        case drag([CGPoint], [Key]), type([TypingToken]), keypress([Key]), wait, screenshot
    }
    private typealias TypingToken = KeyboardInputPlan.TypingToken
    private typealias Key = KeyboardInputPlan.Key
    private struct MouseButton {
        let button: CGMouseButton
        let down: CGEventType
        let up: CGEventType
        static let left = MouseButton(button: .left, down: .leftMouseDown, up: .leftMouseUp)
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
                throw AtmosError.invalidAction("A scroll requires finite scroll_x and scroll_y values within 100,000 pixels.")
            }
            return .scroll(point, Int32(x.rounded()), Int32(y.rounded()), try mouseModifiers(action.keys))
        case "drag":
            guard let path = action.path, (2...1_000).contains(path.count) else {
                throw AtmosError.invalidAction("A drag requires a path containing 2 to 1,000 points.")
            }
            try validateDisplay(frame)
            let points = try path.map { try screenPoint(x: $0.x, y: $0.y, frame: frame) }
            guard action.button == nil || action.button?.lowercased() == "left" else {
                throw AtmosError.invalidAction("A drag currently supports only the left mouse button.")
            }
            return .drag(points, try mouseModifiers(action.keys))
        case "type":
            try rejectExtraKeys(action)
            guard let text = action.text, text.utf16.count <= 100_000 else {
                throw AtmosError.invalidAction("A typing action requires text of at most 100,000 UTF-16 characters.")
            }
            return .type(try KeyboardInputPlan.typingTokens(text))
        case "keypress":
            guard let names = action.keys, !names.isEmpty, names.count <= 5 else {
                throw AtmosError.invalidAction("A keypress requires one key and up to four modifiers.")
            }
            let keys = try names.map(KeyboardInputPlan.key)
            guard Set(keys.map(\.code)).count == keys.count, keys.filter({ $0.modifier.isEmpty }).count <= 1 else {
                throw AtmosError.invalidAction("A shortcut can contain each modifier once and at most one non-modifier key.")
            }
            return .keypress(keys.sorted { !$0.modifier.isEmpty && $1.modifier.isEmpty })
        case "wait": try rejectExtraKeys(action); return .wait
        case "screenshot": try rejectExtraKeys(action); return .screenshot
        default: throw AtmosError.invalidAction("Unsupported computer action: \(action.type).")
        }
    }

    private func mouseModifiers(_ names: [String]?) throws -> [Key] {
        guard let names else { return [] }
        guard names.count <= 4 else {
            throw AtmosError.invalidAction("A mouse action supports at most four modifier keys.")
        }
        let modifiers = try names.map(KeyboardInputPlan.key)
        guard modifiers.allSatisfy({ !$0.modifier.isEmpty }), Set(modifiers.map(\.code)).count == modifiers.count else {
            throw AtmosError.invalidAction("Atmos action keys must be distinct Command, Control, Option, or Shift modifiers.")
        }
        return modifiers
    }

    private func rejectExtraKeys(_ action: ComputerAction) throws {
        guard action.keys?.isEmpty != false else {
            throw AtmosError.invalidAction("The \(action.type) action does not support held keys.")
        }
    }

    private func validateDisplay(_ frame: ScreenshotFrame) throws {
        guard frame.width > 0, frame.height > 0, frame.originX.isFinite, frame.originY.isFinite,
              frame.pointWidth.isFinite, frame.pointHeight.isFinite, frame.pointWidth > 0, frame.pointHeight > 0,
              frame.displayID != 0, CGDisplayIsActive(frame.displayID) != 0 else {
            throw AtmosError.invalidAction("The screenshot has no valid connected display.")
        }
        let captured = CGRect(x: frame.originX, y: frame.originY, width: frame.pointWidth, height: frame.pointHeight)
        guard CGDisplayBounds(frame.displayID) == captured else {
            throw AtmosError.invalidAction("The display arrangement changed. Capture a new screenshot before acting.")
        }
    }

    private func actionPoint(_ action: ComputerAction, frame: ScreenshotFrame) throws -> CGPoint {
        guard let x = action.x, let y = action.y else {
            throw AtmosError.invalidAction("This action requires both x and y coordinates.")
        }
        try validateDisplay(frame)
        return try screenPoint(x: x, y: y, frame: frame)
    }

    private func screenPoint(x: Double, y: Double, frame: ScreenshotFrame) throws -> CGPoint {
        let point = try frame.screenPoint(x: x, y: y)
        guard point.x.isFinite, point.y.isFinite else { throw AtmosError.invalidAction("Invalid screen coordinates.") }
        return CGPoint(x: point.x, y: point.y)
    }

    private func mouseButton(_ name: String) throws -> MouseButton {
        switch name.lowercased() {
        case "left": return .left
        case "right": return MouseButton(button: .right, down: .rightMouseDown, up: .rightMouseUp)
        case "middle", "wheel": return MouseButton(button: .center, down: .otherMouseDown, up: .otherMouseUp)
        case "back": return MouseButton(button: CGMouseButton(rawValue: 3)!, down: .otherMouseDown, up: .otherMouseUp)
        case "forward": return MouseButton(button: CGMouseButton(rawValue: 4)!, down: .otherMouseDown, up: .otherMouseUp)
        default: throw AtmosError.invalidAction("Unsupported mouse button: \(name).")
        }
    }

    private func mouseEvent(_ type: CGEventType, point: CGPoint, button: CGMouseButton, flags: CGEventFlags = []) throws -> CGEvent {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type, mouseCursorPosition: point, mouseButton: button) else {
            throw AtmosError.configuration("Could not create a mouse event.")
        }
        event.flags = flags
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
        return event
    }

    private func click(_ point: CGPoint, button: MouseButton, count: Int, flags: CGEventFlags, timing: PipelineTiming?) async throws {
        for index in 1...count {
            try Task.checkCancellation()
            let down = try mouseEvent(button.down, point: point, button: button.button, flags: flags)
            let up = try mouseEvent(button.up, point: point, button: button.button, flags: flags)
            down.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            up.setIntegerValueField(.mouseEventClickState, value: Int64(index))
            postInput(down, timing: timing)
            // The matching release is posted even if Stop cancels this sleep.
            do { try await pause(milliseconds: 35) } catch { postInput(up, timing: timing); throw error }
            postInput(up, timing: timing)
            if index < count { try await pause(milliseconds: 65) }
        }
    }

    private func drag(_ points: [CGPoint], flags: CGEventFlags, timing: PipelineTiming?) async throws {
        guard let first = points.first else { throw AtmosError.invalidAction("The drag path is empty.") }
        let down = try mouseEvent(.leftMouseDown, point: first, button: .left, flags: flags)
        let up = try mouseEvent(.leftMouseUp, point: first, button: .left, flags: flags)
        // Allocate every event before pressing, so failure cannot strand a button.
        let moves = try points.dropFirst().map { try mouseEvent(.leftMouseDragged, point: $0, button: .left, flags: flags) }
        postInput(down, timing: timing)
        defer { postInput(up, timing: timing) }
        try await pause(milliseconds: 50)
        for move in moves {
            try Task.checkCancellation()
            up.location = move.location
            postInput(move, timing: timing)
            try await pause(milliseconds: 20)
        }
    }

    private func withModifiers(_ modifiers: [Key], timing: PipelineTiming?, operation: (CGEventFlags) async throws -> Void) async throws {
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
                postInput(ups[index], timing: timing)
            }
        }
        for (index, modifier) in modifiers.enumerated() {
            try Task.checkCancellation()
            flags.formUnion(modifier.modifier)
            downs[index].type = .flagsChanged
            downs[index].flags = flags
            postInput(downs[index], timing: timing)
            postedCount += 1
        }
        try Task.checkCancellation()
        try await operation(flags)
        try Task.checkCancellation()
    }

    private func keyboardEvent(_ code: CGKeyCode, down: Bool) throws -> CGEvent {
        guard let event = CGEvent(keyboardEventSource: eventSource, virtualKey: code, keyDown: down) else {
            throw AtmosError.configuration("Could not create a keyboard event.")
        }
        event.flags = []
        event.setIntegerValueField(.keyboardEventAutorepeat, value: 0)
        return event
    }

    private func postKeyPair(_ code: CGKeyCode, timing: PipelineTiming?) throws {
        let down = try keyboardEvent(code, down: true)
        let up = try keyboardEvent(code, down: false)
        postInput(down, timing: timing)
        postInput(up, timing: timing)
    }

    private func postUnicode(_ units: [UniChar], timing: PipelineTiming?) throws {
        let down = try keyboardEvent(0, down: true)
        let up = try keyboardEvent(0, down: false)
        units.withUnsafeBufferPointer { buffer in
            down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
            up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
        }
        postInput(down, timing: timing)
        postInput(up, timing: timing)
    }

    private func press(_ requestedKeys: [Key], timing: PipelineTiming?) async throws {
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
                postInput(ups[index], timing: timing)
            }
        }
        for (index, key) in keys.enumerated() {
            try Task.checkCancellation()
            flags.formUnion(key.modifier)
            downs[index].flags = flags
            if !key.modifier.isEmpty { downs[index].type = .flagsChanged }
            postInput(downs[index], timing: timing)
            postedCount += 1
        }
        try await pause(milliseconds: 40)
    }

    /// Keep the trace local to this action across suspension points. A shared
    /// "current timing" property could attribute another task's events to it.
    private func postInput(_ event: CGEvent, timing: PipelineTiming?) {
        timing?.markFirstInput()
        postEvent(event)
    }

    private func pause(milliseconds: UInt64) async throws {
        try await Task.sleep(nanoseconds: milliseconds * 1_000_000)
    }
}
