import AppKit
import QuartzCore

/// The notch is the interface; loading uses a compact, noninteractive dot ring.
enum MouseOverlayState: Equatable {
    case standby
    case active
    case transcribing(String)
    case thinking
    case working(String)
    case notice(String)
}

@MainActor
final class MouseNotchController {
    private let panel = MouseNotchPanel()
    private let surface = MouseNotchSurface()
    private var state: MouseOverlayState = .standby
    private var transitionID = 0

    init() {
        panel.contentView = surface
    }

    func show(_ nextState: MouseOverlayState) {
        guard nextState != state else { return }
        // This first version follows the primary Mac screen. Space/fullscreen
        // and moving an active session between displays are separate work.
        guard let screen = NSScreen.screens.first ?? NSScreen.main else { return }
        let geometry = MouseNotchGeometry(screen: screen)
        let previousState = state
        state = nextState
        transitionID += 1
        let currentTransition = transitionID
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let present = { [weak self] in
            guard let self, self.transitionID == currentTransition else { return }
            self.present(nextState, after: previousState, geometry: geometry,
                         transition: currentTransition, reduceMotion: reduceMotion)
        }
        if nextState != .thinking, surface.isThinkingVisible {
            // This is purely a presentation transition. Execution does not wait
            // for the dots to leave, and newer states supersede this callback.
            surface.finishThinking(animated: !reduceMotion, completion: present)
        } else {
            present()
        }
    }

    private func present(_ nextState: MouseOverlayState, after previousState: MouseOverlayState,
                         geometry: MouseNotchGeometry, transition currentTransition: Int,
                         reduceMotion: Bool) {
        let duration = reduceMotion ? 0 : 0.30

        if nextState == .standby {
            surface.setText("", font: .systemFont(ofSize: 17), cameraHeight: geometry.cameraHeight,
                            horizontalInset: 24, wraps: false, animate: false)
            guard panel.isVisible else { return }
            panel.alphaValue = 1
            surface.prepareResize(to: geometry.collapsedFrame.size, shoulderRadius: 0)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(geometry.collapsedFrame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.transitionID == currentTransition else { return }
                    self.panel.orderOut(nil)
                }
            }
            return
        }

        let presentation = MouseNotchPresentation(state: nextState, geometry: geometry)
        let wasTranscribing: Bool
        if case .transcribing = previousState { wasTranscribing = true } else { wasTranscribing = false }
        let isTranscribing: Bool
        if case .transcribing = nextState { isTranscribing = true } else { isTranscribing = false }
        surface.setText(presentation.text, font: presentation.font, cameraHeight: geometry.cameraHeight,
                        horizontalInset: presentation.horizontalInset,
                        wraps: presentation.wraps,
                        animate: !reduceMotion && !(wasTranscribing && isTranscribing))
        surface.applyAccessibilityPreferences()
        if nextState == .thinking { surface.startThinking(reduceMotion: reduceMotion) }

        if !panel.isVisible {
            panel.alphaValue = 1
            panel.setFrame(geometry.collapsedFrame, display: false)
            surface.resetCollapsedContour()
            // orderFrontRegardless does not activate the app. The panel cannot
            // become key, and mouse events pass to the application underneath.
            panel.orderFrontRegardless()
        }
        let targetFrame = geometry.frame(size: presentation.size)
        surface.prepareResize(to: targetFrame.size, shoulderRadius: MouseNotchContour.shoulderRadius)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func hide() { show(.standby) }
}

private final class MouseNotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Mouse"
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        canHide = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.stationary, .ignoresCycle]
        // NativeComputer excludes our process from its captures. Leave normal
        // sharing enabled so the user can capture the interface itself.
        setAccessibilityLabel("Mouse voice interface")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // AppKit otherwise pushes the panel below the menu-bar/notch safe area.
        // Our geometry already anchors it to the physical top edge of the screen.
        frameRect
    }
}

private enum MouseNotchContour {
    // A fixed-size, concave shoulder turns each side into the screen edge.
    // Keep it small even when a long transcript expands the body.
    static let shoulderRadius: CGFloat = 6
}

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

private struct MouseNotchGeometry {
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

private struct MouseNotchPresentation {
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

/// The body retains native glass refraction along its sides and lower corners.
/// A black cap adds concave shoulders where it joins the physical screen edge.
private final class MouseNotchSurface: NSView {
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
