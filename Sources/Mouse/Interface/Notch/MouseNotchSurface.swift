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

/// Native glass surrounds the measured camera cutout. Only that cutout stays
/// black; its tint eases out across the extension to the visible panel edges.
final class MouseNotchSurface: NSView {
    private let radius: CGFloat = 22
    private let glass = NSGlassEffectView()
    private let content = MouseNotchContent()
    private let shoulders = CAShapeLayer()
    private let glassFade = CAGradientLayer()
    private let edgeOverlay = NSView()
    private let edge = CAShapeLayer()
    private let edgeFade = CAGradientLayer()
    private var contourResize = MouseNotchContourResize()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        glass.style = .clear
        glass.cornerRadius = radius
        // The notch always uses light text, regardless of the app's appearance.
        glass.appearance = NSAppearance(named: .darkAqua)
        glass.wantsLayer = true
        glass.layer?.mask = glassFade
        addSubview(glass)
        // Keep text and the camera blend outside the material's edge fade.
        // Fading the whole content view would make the camera seam reappear.
        content.layer?.cornerRadius = radius
        content.layer?.masksToBounds = true
        addSubview(content)
        layer?.addSublayer(shoulders)
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.withAlphaComponent(0.38).cgColor
        edge.lineWidth = 0.75
        edge.mask = edgeFade
        // An explicit view preserves this order when AppKit rebuilds the
        // material's backing layers during window resizing.
        edgeOverlay.wantsLayer = true
        edgeOverlay.layer?.addSublayer(edge)
        addSubview(edgeOverlay, positioned: .above, relativeTo: content)
        applyAccessibilityPreferences()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let shoulder = min(contourResize.radius(at: bounds.size), bounds.width / 2, bounds.height)
        glass.frame = NSRect(x: shoulder, y: 0, width: max(0, bounds.width - shoulder * 2),
                             height: bounds.height + radius)
        content.frame = glass.frame
        content.extraTopInset = radius

        // These are outward shoulders, not rounded rectangle corners. Each
        // quarter-circle is tangent to the top edge and the vertical body.
        let top = bounds.height
        let right = bounds.width
        let tangent = shoulder * 0.5522847498
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: top))
        path.addLine(to: CGPoint(x: shoulder, y: top))
        path.addLine(to: CGPoint(x: shoulder, y: top - shoulder))
        path.addCurve(to: CGPoint(x: 0, y: top),
                      control1: CGPoint(x: shoulder, y: top - shoulder + tangent),
                      control2: CGPoint(x: tangent, y: top))
        path.closeSubpath()
        path.move(to: CGPoint(x: right - shoulder, y: top))
        path.addLine(to: CGPoint(x: right, y: top))
        path.addCurve(to: CGPoint(x: right - shoulder, y: top - shoulder),
                      control1: CGPoint(x: right - tangent, y: top),
                      control2: CGPoint(x: right - shoulder, y: top - shoulder + tangent))
        path.closeSubpath()

        // Window resizing already supplies animation frames. Updating this
        // path immediately prevents the cap from trailing behind the glass.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shoulders.frame = bounds
        shoulders.path = path
        shoulders.contentsScale = window?.backingScaleFactor ?? 2
        // The native rim and the added glint disappear before reaching the
        // screen's top corners. The shoulders themselves have no white stroke.
        updateFade(glassFade, frame: glass.bounds, visibleTop: top)
        updateFade(edgeFade, frame: bounds, visibleTop: top)
        edgeOverlay.frame = bounds
        edge.frame = edgeOverlay.bounds
        edge.path = edgePath(in: glass.frame, top: top - shoulder)
        edge.contentsScale = shoulders.contentsScale
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

    func setText(_ text: String, font: NSFont, cameraWidth: CGFloat, cameraHeight: CGFloat, horizontalInset: CGFloat, wraps: Bool, animate: Bool) {
        content.setText(text, font: font, cameraWidth: cameraWidth, cameraHeight: cameraHeight,
                        horizontalInset: horizontalInset, wraps: wraps, animate: animate)
    }

    func applyAccessibilityPreferences() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        content.reduceTransparency = reduceTransparency
        glass.style = reduceTransparency ? .regular : .clear
        shoulders.fillColor = (reduceTransparency
            ? NSColor(white: 0.12, alpha: 1)
            : NSColor.black.withAlphaComponent(0.12)).cgColor
        needsLayout = true
    }

    private func updateFade(_ fade: CAGradientLayer, frame: NSRect, visibleTop: CGFloat) {
        let height = max(1, frame.height)
        fade.frame = frame
        fade.startPoint = CGPoint(x: 0.5, y: 0)
        fade.endPoint = CGPoint(x: 0.5, y: 1)
        fade.colors = [NSColor.white.cgColor, NSColor.white.cgColor,
                       NSColor.clear.cgColor, NSColor.clear.cgColor]
        fade.locations = [0, NSNumber(value: max(0, visibleTop - 24) / height),
                          NSNumber(value: max(0, visibleTop - 3) / height), 1]
    }

    private func edgePath(in body: NSRect, top: CGFloat) -> CGPath {
        let inset: CGFloat = 0.5
        let left = body.minX + inset
        let right = body.maxX - inset
        let bottom = inset
        let corner = max(0, min(radius, (right - left) / 2, top - bottom))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left, y: max(bottom, top)))
        path.addLine(to: CGPoint(x: left, y: bottom + corner))
        path.addArc(tangent1End: CGPoint(x: left, y: bottom),
                    tangent2End: CGPoint(x: left + corner, y: bottom), radius: corner)
        path.addLine(to: CGPoint(x: right - corner, y: bottom))
        path.addArc(tangent1End: CGPoint(x: right, y: bottom),
                    tangent2End: CGPoint(x: right, y: bottom + corner), radius: corner)
        path.addLine(to: CGPoint(x: right, y: max(bottom, top)))
        return path
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
    private var cameraWidth: CGFloat = 0
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
            // An opaque charcoal fallback respects Reduce Transparency while
            // reserving full black for the physical camera cutout.
            NSColor(white: 0.12, alpha: 1).setFill()
            bounds.fill()
        } else {
            NSColor.black.withAlphaComponent(0.12).setFill()
            bounds.fill()
        }
        drawCameraBlend()
    }

    private func drawCameraBlend() {
        // Displays without a camera cutout get glass throughout, not a fake
        // black notch. AppKit coordinates begin at the bottom of this view.
        guard cameraWidth > 0, cameraHeight > 0 else { return }
        let camera = NSRect(x: (bounds.width - cameraWidth) / 2,
                            y: bounds.height - extraTopInset - cameraHeight,
                            width: cameraWidth, height: cameraHeight + extraTopInset + 8)
        let cameraCorner: CGFloat = 8
        let panelCorner: CGFloat = 22
        let steps = 128
        var previousAlpha: CGFloat = 0
        // Scale the transition to this presentation's sides and bottom rather
        // than ending a fixed distance from the camera. A shared top, above the
        // clipped screen edge, keeps every rounded contour nested while resizing.
        // Smoothstep has zero slope at both ends, avoiding a visible cutoff at
        // either the hardware seam or the clear outer glass.
        for step in 1..<steps {
            let progress = CGFloat(step) / CGFloat(steps)
            let left = bounds.minX + (camera.minX - bounds.minX) * progress
            let bottom = bounds.minY + (camera.minY - bounds.minY) * progress
            let width = bounds.width + (camera.width - bounds.width) * progress
            let contour = NSRect(x: left, y: bottom, width: width, height: camera.maxY - bottom)
            let corner = panelCorner + (cameraCorner - panelCorner) * progress
            let alpha = progress * progress * (3 - 2 * progress)
            // Source-over compensation keeps overlapping fills at the desired
            // opacity. Leave the opaque endpoint to the exact camera fill below.
            NSColor.black.withAlphaComponent((alpha - previousAlpha) / (1 - previousAlpha)).setFill()
            NSBezierPath(roundedRect: contour, xRadius: corner, yRadius: corner).fill()
            previousAlpha = alpha
        }
        NSColor.black.setFill()
        NSBezierPath(roundedRect: camera, xRadius: cameraCorner, yRadius: cameraCorner).fill()
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

    func setText(_ text: String, font: NSFont, cameraWidth: CGFloat, cameraHeight: CGFloat, horizontalInset: CGFloat, wraps: Bool, animate: Bool) {
        textRevision += 1
        let revision = textRevision
        self.cameraWidth = cameraWidth
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
