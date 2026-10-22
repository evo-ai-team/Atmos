import Carbon.HIToolbox
import CoreGraphics
import Foundation
#if SWIFT_PACKAGE
import MouseCore
#endif

/// Converts requested text and shortcuts into a complete input plan before any
/// event is posted. Layout lookup stays separate from key-down/key-up ownership.
enum KeyboardInputPlan {
    enum TypingToken {
        case text([UniChar])
        case key(CGKeyCode)
    }

    struct Key {
        let code: CGKeyCode
        var modifier: CGEventFlags = []
        var implicitFlags: CGEventFlags = []
    }

    static func typingTokens(_ text: String) throws -> [TypingToken] {
        var result: [TypingToken] = []
        var buffer: [UniChar] = []
        func flush() {
            guard !buffer.isEmpty else { return }
            result.append(.text(buffer))
            buffer.removeAll(keepingCapacity: true)
        }
        // Return and Tab need key events; printable scalars use Unicode packets.
        // Normalize line endings first so CRLF cannot produce two Return presses.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for scalar in normalized.unicodeScalars {
            if scalar == "\n" {
                flush()
                result.append(.key(36))
                continue
            }
            if scalar == "\t" {
                flush()
                result.append(.key(48))
                continue
            }
            guard scalar.value >= 0x20, !(0x7F...0x9F).contains(scalar.value) else {
                throw MouseError.invalidAction("Typed text contains an unsupported control character.")
            }
            // Keep each Unicode scalar intact, including UTF-16 surrogate pairs,
            // when splitting text into small event payloads.
            let units = Array(String(scalar).utf16)
            if buffer.count + units.count > 20 { flush() }
            buffer.append(contentsOf: units)
        }
        flush()
        return result
    }

    static func key(_ name: String) throws -> Key {
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
        guard value.count == 1 else { throw MouseError.invalidAction("Unsupported key: \(name).") }
        // Resolve printable shortcut keys against the current ASCII-capable layout
        // instead of assuming the user's keyboard has US physical key positions.
        if let found = printableKey(value) { return found }
        throw MouseError.invalidAction("The current keyboard layout has no supported key for \(name).")
    }

    private static func printableKey(_ character: String) -> Key? {
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

}
