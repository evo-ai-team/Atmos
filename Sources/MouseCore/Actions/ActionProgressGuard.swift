import Foundation

/// Detects a narrow kind of stalled loop, not whether an action succeeded.
/// Compare encoded images exactly: animation, cursor changes, JPEG differences,
/// or a changing overlay can hide a loop from this guard. Avoiding false visual
/// equivalence is preferable to stopping useful work based on a rough image match.
/// Record only successfully dispatched batches and their fresh observations.
public struct ActionProgressGuard: Sendable {
    private enum Signature: Equatable, Sendable {
        case generated([ComputerAction])
        // AX IDs belong to one capture; the same control gets a new ID next time.
        case native(action: String, role: String, subrole: String?, label: String?, bounds: AccessibilityBounds?)
    }

    private var signature: Signature?
    private var lastFrame: ScreenshotFrame?
    private var lastProcessID: Int32?
    private var consecutiveUnchanged = 0

    public init() {}

    public mutating func reset() {
        signature = nil
        lastFrame = nil
        lastProcessID = nil
        consecutiveUnchanged = 0
    }

    public mutating func recordGenerated(_ actions: [ComputerAction], before: ScreenshotFrame,
                                         after: ScreenshotFrame, processIDBefore: Int32,
                                         processIDAfter: Int32) -> String? {
        // Waiting deliberately sends no input. Even a mixed batch containing a
        // wait may be polling a legitimate transition, so it breaks the streak.
        guard !actions.isEmpty, !actions.contains(where: { $0.type.lowercased() == "wait" }) else {
            reset()
            return nil
        }
        return record(.generated(actions), before: before, after: after,
                      processIDBefore: processIDBefore, processIDAfter: processIDAfter,
                      observationOnly: actions.allSatisfy { $0.type.lowercased() == "screenshot" })
    }

    public mutating func recordNative(action: String, element: AccessibilityElement,
                                      before: ScreenshotFrame, after: ScreenshotFrame,
                                      processIDBefore: Int32, processIDAfter: Int32) -> String? {
        // Fine-grained values can advance without changing rendered pixels.
        // An image-only guard cannot establish a stalled increment/decrement.
        guard action != "AXIncrement", action != "AXDecrement" else {
            reset()
            return nil
        }
        return record(.native(action: action, role: element.role, subrole: element.subrole,
                       label: element.label, bounds: element.screenBounds),
               before: before, after: after, processIDBefore: processIDBefore,
               processIDAfter: processIDAfter, observationOnly: false)
    }

    private mutating func record(_ current: Signature, before: ScreenshotFrame, after: ScreenshotFrame,
                                 processIDBefore: Int32, processIDAfter: Int32,
                                 observationOnly: Bool) -> String? {
        guard processIDBefore > 0, processIDBefore == processIDAfter,
              Self.sameFrame(before, after) else {
            reset()
            return nil
        }
        // Also compare across batches: two individually unchanged observations
        // must not form a streak if the application changed between them.
        let continues = signature == current && lastProcessID == processIDBefore
            && lastFrame.map { Self.sameFrame($0, before) } == true
        consecutiveUnchanged = continues ? min(consecutiveUnchanged + 1, 3) : 1
        signature = current
        lastFrame = after
        lastProcessID = processIDAfter
        guard consecutiveUnchanged >= 3 else { return nil }
        if observationOnly {
            return "Mouse checked the same screen three times without sending input. It paused instead of repeating that observation."
        }
        return "The same input was sent three times, but the captured screen stayed exactly the same. Mouse paused instead of repeating it again."
    }

    private static func sameFrame(_ lhs: ScreenshotFrame, _ rhs: ScreenshotFrame) -> Bool {
        // Empty or invalid capture metadata is not evidence of a frozen screen.
        !lhs.data.isEmpty && lhs.width > 0 && lhs.height > 0
            && lhs.originX.isFinite && lhs.originY.isFinite
            && lhs.pointWidth.isFinite && lhs.pointHeight.isFinite
            && lhs.pointWidth > 0 && lhs.pointHeight > 0
            && lhs.displayID == rhs.displayID
            && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.originX == rhs.originX && lhs.originY == rhs.originY
            && lhs.pointWidth == rhs.pointWidth && lhs.pointHeight == rhs.pointHeight
            && lhs.data == rhs.data
    }
}
