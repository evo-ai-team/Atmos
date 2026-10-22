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

/// A vertical dark-to-glass tint fills the notch silhouette. Only the measured
/// camera cutout is opaque; the bottom keeps a faint dark backing and bright rim.
final class MouseNotchSurface: NSView {
    private let radius: CGFloat = 22
    private let glass = NSGlassEffectView()
    private let content = MouseNotchContent()
    private let shoulders = CAShapeLayer()
    private let edgeOverlay = NSView()
    private let edgeClip = CAShapeLayer()
    private let rimShade = CAShapeLayer()
    private let rimShadeFade = CAGradientLayer()
    private let edge = CAShapeLayer()
    private let edgeFade = CAGradientLayer()
    private var contourResize = MouseNotchContourResize()
    private var hasCameraCutout = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        glass.style = .clear
        glass.cornerRadius = radius
        // Leave native glass at full strength. Reducing its alpha blends the
        // untreated background back in and weakens the material's refraction.
        // Control darkness with the content's tint rather than material opacity.
        glass.tintColor = nil
        content.layer?.cornerRadius = radius
        content.layer?.masksToBounds = true
        // AppKit treats foreground content correctly when it belongs to the
        // material. A sibling view above an empty glass view bypasses that path.
        glass.contentView = content
        addSubview(glass)
        layer?.addSublayer(shoulders)
        edge.fillColor = nil
        edge.strokeColor = NSColor.white.cgColor
        edge.lineWidth = 0.85
        // Finish the fade before the shoulders, leaving the upper sides fully
        // unlit. Native glass has its own rim, so a thin dark stroke above the
        // material attenuates that rim with the inverse of this same fade.
        edgeFade.startPoint = CGPoint(x: 0.5, y: 0)
        edgeFade.endPoint = CGPoint(x: 0.5, y: 1)
        let light: [CGFloat] = [0.78, 0.52, 0.16, 0, 0]
        edgeFade.colors = light.map {
            NSColor.white.withAlphaComponent($0).cgColor
        }
        edgeFade.locations = [0, 0.18, 0.48, 0.72, 1]
        rimShadeFade.startPoint = edgeFade.startPoint
        rimShadeFade.endPoint = edgeFade.endPoint
        rimShadeFade.locations = edgeFade.locations
        rimShadeFade.colors = light.map {
            NSColor.black.withAlphaComponent(1 - $0 / light[0]).cgColor
        }
        rimShade.fillColor = nil
        rimShade.strokeColor = NSColor.black.cgColor
        rimShade.lineWidth = 1
        rimShade.mask = rimShadeFade
        edge.mask = edgeFade
        // Clip the narrow cover to the body so it cannot draw a dark outline
        // outside the glass. The material itself stays unmasked at full alpha.
        edgeOverlay.wantsLayer = true
        edgeClip.fillColor = NSColor.black.cgColor
        edgeOverlay.layer?.mask = edgeClip
        edgeOverlay.layer?.addSublayer(rimShade)
        edgeOverlay.layer?.addSublayer(edge)
        addSubview(edgeOverlay, positioned: .above, relativeTo: glass)
        applyAccessibilityPreferences()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        let shoulder = min(contourResize.radius(at: bounds.size), bounds.width / 2, bounds.height)
        glass.frame = NSRect(x: shoulder, y: 0, width: max(0, bounds.width - shoulder * 2),
                             height: bounds.height + radius)
        content.frame = glass.bounds
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
        edgeOverlay.frame = bounds
        edgeClip.frame = bounds
        edgeClip.path = CGPath(roundedRect: glass.frame, cornerWidth: radius,
                               cornerHeight: radius, transform: nil)
        edgeFade.frame = bounds
        rimShadeFade.frame = bounds
        let outline = edgePath(in: glass.frame, top: top - shoulder)
        let nativeRim = edgePath(in: glass.frame, top: top)
        for stroke in [rimShade, edge] {
            stroke.frame = edgeOverlay.bounds
            stroke.path = stroke === edge ? outline : nativeRim
            stroke.contentsScale = shoulders.contentsScale
        }
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
        let hasCamera = cameraWidth > 0 && cameraHeight > 0
        if hasCameraCutout != hasCamera {
            hasCameraCutout = hasCamera
            applyAccessibilityPreferences()
        }
        content.setText(text, font: font, cameraWidth: cameraWidth, cameraHeight: cameraHeight,
                        horizontalInset: horizontalInset, wraps: wraps, animate: animate)
    }

    func applyAccessibilityPreferences() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        content.reduceTransparency = reduceTransparency
        glass.style = reduceTransparency ? .regular : .clear
        // Match the body's top tint, including on displays with no camera.
        shoulders.fillColor = (reduceTransparency
            ? NSColor(white: 0.12, alpha: 1)
            : NSColor.black.withAlphaComponent(hasCameraCutout ? 0.98 : 0.10)).cgColor
        needsLayout = true
    }

    private func edgePath(in body: NSRect, top: CGFloat) -> CGPath {
        let inset: CGFloat = 0.5
        let left = body.minX + inset
        let right = body.maxX - inset
        let bottom = inset
        // Keep the inset stroke concentric with the native glass corner.
        let corner = max(0, min(radius - inset, (right - left) / 2, top - bottom))
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
            drawGlassTint()
        }
        drawCameraCutout()
    }

    private func drawGlassTint() {
        // Keep every horizontal slice the same opacity. The outer view clips
        // this vertical gradient to the silhouette; there is no sideways fade.
        guard cameraWidth > 0, cameraHeight > 0 else {
            NSColor.black.withAlphaComponent(0.10).setFill()
            bounds.fill()
            return
        }
        // Stay nearly black through the camera's height, then fade across the
        // extension to a 10% backing at the bottom. Exclude the offscreen inset
        // so short and expanded presentations meet the same hardware seam.
        let fadeHeight = max(1, bounds.height - extraTopInset - cameraHeight)
        NSGradient(colorsAndLocations:
            (NSColor.black.withAlphaComponent(0.10), 0),
            (NSColor.black.withAlphaComponent(0.22), 0.22),
            (NSColor.black.withAlphaComponent(0.62), 0.55),
            (NSColor.black.withAlphaComponent(0.93), 0.82),
            (NSColor.black.withAlphaComponent(0.98), 1))?.draw(
                from: NSPoint(x: bounds.midX, y: 0),
                to: NSPoint(x: bounds.midX, y: fadeHeight),
                options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
    }

    private func drawCameraCutout() {
        // The exact hardware cutout remains black above the separate tint.
        // Displays without a cutout never get a synthetic black camera region.
        guard cameraWidth > 0, cameraHeight > 0 else { return }
        let camera = NSRect(x: (bounds.width - cameraWidth) / 2,
                            y: bounds.height - extraTopInset - cameraHeight,
                            width: cameraWidth, height: cameraHeight + extraTopInset + 8)
        NSColor.black.setFill()
        NSBezierPath(roundedRect: camera, xRadius: 8, yRadius: 8).fill()
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
