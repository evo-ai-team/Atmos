import AppKit
import QuartzCore

/// Derive the shoulder inset from the window's current size, so there is only
/// one animation clock. A fixed inset would let the visible sides cross into
/// the hardware notch before the bottom arrives there.
private struct MouseNotchContourResize {
    var startSize: NSSize = .zero
    var targetSize: NSSize = .zero
    var startRadius: CGFloat = 0
    var targetRadius: CGFloat = 0

    func radius(at size: NSSize) -> CGFloat {
        let widthChange = targetSize.width - startSize.width
        let heightChange = targetSize.height - startSize.height
        let change: CGFloat
        let traveled: CGFloat
        if abs(widthChange) >= abs(heightChange) {
            change = widthChange
            traveled = size.width - startSize.width
        } else {
            change = heightChange
            traveled = size.height - startSize.height
        }
        guard abs(change) > 0.001 else { return targetRadius }
        let progress = max(0, min(1, traveled / change))
        return startRadius + (targetRadius - startRadius) * progress
    }
}

/// The body retains native glass refraction along its sides and lower corners.
/// A black cap adds concave shoulders where it joins the physical screen edge.
final class MouseNotchSurface: NSView {
    private let radius: CGFloat = 22
    private let glass = NSGlassEffectView()
    private let content = MouseNotchContent()
    private let shoulders = CAShapeLayer()
    private var contourResize = MouseNotchContourResize()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        glass.style = .clear
        glass.cornerRadius = radius
        glass.contentView = content
        addSubview(glass)
        shoulders.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shoulders)
        applyAccessibilityPreferences()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let shoulder = min(contourResize.radius(at: bounds.size), bounds.width / 2, bounds.height)
        glass.frame = NSRect(x: shoulder, y: 0, width: max(0, bounds.width - shoulder * 2),
                             height: bounds.height + radius)
        content.extraTopInset = radius

        // These are outward shoulders, not rounded rectangle corners. Each
        // quarter-circle is tangent to the top edge and the vertical body.
        let top = bounds.height
        let right = bounds.width
        let tangent = shoulder * 0.5522847498
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addCurve(to: CGPoint(x: right - shoulder, y: top - shoulder),
                      control1: CGPoint(x: right - tangent, y: top),
                      control2: CGPoint(x: right - shoulder, y: top - shoulder + tangent))
        path.addLine(to: CGPoint(x: shoulder, y: top - shoulder))
        path.addCurve(to: CGPoint(x: 0, y: top),
                      control1: CGPoint(x: shoulder, y: top - shoulder + tangent),
                      control2: CGPoint(x: tangent, y: top))
        path.closeSubpath()

        // Window resizing already supplies animation frames. Updating this
        // path immediately prevents the cap from trailing behind the glass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shoulders.frame = bounds
        shoulders.path = path
        shoulders.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    func resetCollapsedContour() {
        contourResize = MouseNotchContourResize()
        needsLayout = true
    }

    func prepareResize(to size: NSSize, shoulderRadius: CGFloat) {
        // On interruption, continue from the actual current contour instead of
        // snapping its shoulders back to their fully expanded size.
        contourResize = MouseNotchContourResize(
            startSize: bounds.size, targetSize: size,
            startRadius: contourResize.radius(at: bounds.size), targetRadius: shoulderRadius)
        needsLayout = true
    }

    func setText(_ text: String, font: NSFont, cameraHeight: CGFloat, horizontalInset: CGFloat, wraps: Bool, animate: Bool) {
        content.setText(text, font: font, cameraHeight: cameraHeight, horizontalInset: horizontalInset, wraps: wraps, animate: animate)
    }

    func applyAccessibilityPreferences() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        content.reduceTransparency = reduceTransparency
        glass.style = reduceTransparency ? .regular : .clear
    }

    var isThinkingVisible: Bool { content.thinkingIndicator.isVisible }
    func startThinking(reduceMotion: Bool) { content.thinkingIndicator.start(reduceMotion: reduceMotion) }
    func finishThinking(animated: Bool, completion: @escaping () -> Void) {
        content.thinkingIndicator.finish(animated: animated, completion: completion)
    }
}

private final class MouseNotchContent: NSView {
    private let label = NSTextField(labelWithString: "")
    let thinkingIndicator = MouseThinkingIndicator()
    private var textRevision = 0
    private var cameraHeight: CGFloat = 0
    private var horizontalInset: CGFloat = 24
    var extraTopInset: CGFloat = 22 { didSet { needsLayout = true; needsDisplay = true } }
    var reduceTransparency = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.isSelectable = false
        label.isEditable = false
        label.drawsBackground = false
        label.textColor = .white
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)
        addSubview(thinkingIndicator)
    }

    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if reduceTransparency {
            NSColor.black.setFill()
            bounds.fill()
            return
        }
        // NSView coordinates run from the bottom. The hardware camera's entire
        // row stays solid black, then softens into the native material below.
        let visibleHeight = max(1, bounds.height - extraTopInset)
        let blackStart = max(0, min(0.82, (visibleHeight - cameraHeight - 5) / max(1, bounds.height)))
        NSGradient(colorsAndLocations:
            (NSColor.black.withAlphaComponent(0.12), 0),
            (NSColor.black.withAlphaComponent(0.76), max(0.06, min(blackStart * 0.55, 18 / max(1, bounds.height)))),
            (NSColor.black, max(0.12, blackStart)),
            (NSColor.black, 1))?.draw(in: bounds, angle: 90)
    }

    override func layout() {
        super.layout()
        let top = bounds.height - extraTopInset - cameraHeight - 10
        let width = max(0, bounds.width - horizontalInset * 2)
        let measured = label.attributedStringValue.boundingRect(
            with: NSSize(width: max(1, width - 4), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        let font = label.attributedStringValue.length > 0
            ? label.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            : nil
        let height = label.maximumNumberOfLines == 1
            ? ceil((font?.ascender ?? 17) - (font?.descender ?? -4) + (font?.leading ?? 0))
            : ceil(measured.height)
        label.frame = NSRect(x: horizontalInset, y: max(0, top - height), width: width, height: height)
        let indicatorSide = MouseThinkingIndicator.preferredSide
        thinkingIndicator.frame = NSRect(x: (bounds.width - indicatorSide) / 2,
                                         y: max(0, top - indicatorSide),
                                         width: indicatorSide, height: indicatorSide)
        needsDisplay = true
    }

    func setText(_ text: String, font: NSFont, cameraHeight: CGFloat, horizontalInset: CGFloat, wraps: Bool, animate: Bool) {
        textRevision += 1
        let revision = textRevision
        self.cameraHeight = cameraHeight
        self.horizontalInset = horizontalInset
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byTruncatingTail
        paragraph.alignment = wraps ? .left : .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
        let updateText = { [weak self] in
            guard let self, self.textRevision == revision else { return }
            self.label.maximumNumberOfLines = wraps ? 0 : 1
            self.label.attributedStringValue = attributed
            self.label.setAccessibilityLabel(text)
            self.needsLayout = true
        }
        guard animate, !label.stringValue.isEmpty, label.stringValue != text else {
            updateText()
            label.alphaValue = 1
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            label.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            guard let self, self.textRevision == revision else { return }
            updateText()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                self.label.animator().alphaValue = 1
            }
        }
    }
}
