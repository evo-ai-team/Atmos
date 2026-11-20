import Foundation

/// An encoded screenshot and its original Quartz display geometry. Model coordinates
/// refer to image pixels; dispatch converts them back to global screen points.
public struct ScreenshotFrame: Sendable {
    public var data: Data
    public var width: Int
    public var height: Int
    public var originX: Double
    public var originY: Double
    public var pointWidth: Double
    public var pointHeight: Double
    public var displayID: UInt32
    public init(data: Data, width: Int, height: Int, originX: Double = 0, originY: Double = 0, pointWidth: Double, pointHeight: Double, displayID: UInt32 = 0) {
        self.data = data
        self.width = width
        self.height = height
        self.originX = originX
        self.originY = originY
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.displayID = displayID
    }
    /// Reject off-image coordinates before scaling. Display origins may be negative
    /// when a monitor sits above or to the left of the primary display.
    public func screenPoint(x: Double, y: Double) throws -> ActionPoint {
        guard width > 0, height > 0,
              originX.isFinite, originY.isFinite,
              pointWidth.isFinite, pointHeight.isFinite, pointWidth > 0, pointHeight > 0,
              x.isFinite, y.isFinite, x >= 0, y >= 0,
              x < Double(width), y < Double(height) else {
            throw MouseError.invalidAction("Coordinates are outside the captured display.")
        }
        return ActionPoint(x: originX + x * pointWidth / Double(width), y: originY + y * pointHeight / Double(height))
    }
    public var dataURL: String { "data:image/jpeg;base64," + data.base64EncodedString() }
}
