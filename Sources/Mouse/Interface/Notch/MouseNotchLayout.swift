import AppKit

enum MouseNotchContour {
    // A fixed-size, concave shoulder turns each side into the screen edge.
    // Keep it small even when a long transcript expands the body.
    static let shoulderRadius: CGFloat = 6
}

struct MouseNotchGeometry {
    let screenFrame: NSRect
    let centerX: CGFloat
    let cameraWidth: CGFloat
    let cameraHeight: CGFloat

    init(screen: NSScreen) {
        screenFrame = screen.frame
        let left = screen.auxiliaryTopLeftArea ?? .zero
        let right = screen.auxiliaryTopRightArea ?? .zero
        let measuredWidth = right.minX - left.maxX
        let hasCamera = screen.safeAreaInsets.top > 0 && !left.isEmpty && !right.isEmpty && measuredWidth > 0
        cameraWidth = hasCamera ? measuredWidth : 160
        cameraHeight = hasCamera ? screen.safeAreaInsets.top : 0
        centerX = hasCamera ? (left.maxX + right.minX) / 2 : screen.frame.midX
    }

    var collapsedFrame: NSRect {
        // The entire silhouette, including its shoulders, must fit inside the
        // hardware notch before the panel disappears.
        anchoredFrame(size: NSSize(width: cameraWidth, height: max(1, cameraHeight)))
    }

    func frame(size: NSSize) -> NSRect {
        // Leave the glass body and text layout at their existing widths; only
        // the small shoulders extend beyond its sides.
        anchoredFrame(size: NSSize(width: size.width + MouseNotchContour.shoulderRadius * 2,
                                   height: size.height))
    }

    private func anchoredFrame(size: NSSize) -> NSRect {
        NSRect(x: centerX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}

struct MouseNotchPresentation {
    let text: String
    let font: NSFont
    let horizontalInset: CGFloat
    let wraps: Bool
    let size: NSSize

    init(state: MouseOverlayState, geometry: MouseNotchGeometry) {
        let availableWidth = max(200, geometry.screenFrame.width - 48)
        switch state {
        case .standby, .active:
            text = ""
            font = .systemFont(ofSize: 17, weight: .regular)
            horizontalInset = 24
            wraps = false
            size = NSSize(width: min(geometry.cameraWidth + 40, availableWidth),
                          height: max(30, geometry.cameraHeight + 18))
        case .thinking:
            text = ""
            font = .systemFont(ofSize: 16, weight: .medium)
            horizontalInset = 24
            wraps = false
            size = NSSize(width: min(geometry.cameraWidth + 16, availableWidth),
                          height: geometry.cameraHeight + 56)
        case .transcribing(let transcript), .notice(let transcript):
            text = transcript
            font = .systemFont(ofSize: 17, weight: .regular)
            horizontalInset = 24
            wraps = true
            let width = min(460, availableWidth)
            let textHeight = Self.textHeight(transcript, font: font, width: width - 52)
            size = NSSize(width: width,
                          height: geometry.cameraHeight + 14 + textHeight + 23)
        case .working(let description):
            // Status is kept to one line. The model's description is already
            // constrained to a short phrase; the label truncates as a fallback.
            text = description.replacingOccurrences(of: "\n", with: " ")
            font = .systemFont(ofSize: 16, weight: .medium)
            horizontalInset = 24
            wraps = false
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            size = NSSize(width: min(max(geometry.cameraWidth + 68, textWidth + 48), min(460, availableWidth)),
                          height: geometry.cameraHeight + 49)
        }
    }

    private static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 3
        let rect = ((text.isEmpty ? " " : text) as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraph])
        return max(ceil(font.ascender - font.descender + font.leading), ceil(rect.height))
    }
}

