import AppKit
import QuartzCore

/// The notch is deliberately the whole interface: no controls or activity dots.
enum MouseOverlayState: Equatable {
    case standby
    case active
    case transcribing(String)
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
        let duration = reduceMotion ? 0 : 0.30

        if nextState == .standby {
            surface.setText("", font: .systemFont(ofSize: 17), cameraHeight: geometry.cameraHeight,
                            horizontalInset: 24, animate: false)
            guard panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = duration
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(geometry.collapsedFrame, display: true)
                panel.animator().alphaValue = 0
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
                        animate: !reduceMotion && !(wasTranscribing && isTranscribing))
        surface.applyAccessibilityPreferences()

        if !panel.isVisible {
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.setFrame(geometry.collapsedFrame, display: false)
            // orderFrontRegardless does not activate the app. The panel cannot
            // become key, and mouse events pass to the application underneath.
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
            panel.animator().setFrame(geometry.frame(size: presentation.size), display: true)
            panel.animator().alphaValue = 1
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
        frame(size: NSSize(width: cameraWidth, height: max(1, cameraHeight)))
    }

    func frame(size: NSSize) -> NSRect {
        NSRect(x: centerX - size.width / 2, y: screenFrame.maxY - size.height,
               width: size.width, height: size.height)
    }
}

private struct MouseNotchPresentation {
    let text: String
    let font: NSFont
    let horizontalInset: CGFloat
    let size: NSSize

    init(state: MouseOverlayState, geometry: MouseNotchGeometry) {
        let availableWidth = max(200, geometry.screenFrame.width - 48)
        switch state {
        case .standby, .active:
            text = ""
            font = .systemFont(ofSize: 17, weight: .regular)
            horizontalInset = 24
            size = NSSize(width: min(geometry.cameraWidth + 40, availableWidth),
                          height: max(30, geometry.cameraHeight + 18))
        case .transcribing(let transcript), .notice(let transcript):
            text = transcript
            font = .systemFont(ofSize: 18, weight: .regular)
            horizontalInset = 24
            let width = min(460, availableWidth)
            let textHeight = Self.textHeight(transcript, font: font, width: width - 52)
            size = NSSize(width: width,
                          height: geometry.cameraHeight + 14 + textHeight + 23)
        case .working(let description):
            // Status is kept to one line. The model's description is already
            // constrained to a short phrase; the label truncates as a fallback.
            text = description.replacingOccurrences(of: "\n", with: " ")
            font = .systemFont(ofSize: 17, weight: .medium)
            horizontalInset = 24
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

/// Extending the native rounded glass above the screen clips off its upper
/// corners. That leaves filled upper corners and straight sides, while keeping
/// genuine native refraction along the two visible lower corners.
private final class MouseNotchSurface: NSView {
    private let radius: CGFloat = 22
    private let glass = NSGlassEffectView()
    private let content = MouseNotchContent()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        glass.style = .clear
        glass.cornerRadius = radius
        glass.contentView = content
        addSubview(glass)
        applyAccessibilityPreferences()
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        glass.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height + radius)
        content.extraTopInset = radius
    }

    func setText(_ text: String, font: NSFont, cameraHeight: CGFloat, horizontalInset: CGFloat, animate: Bool) {
        content.setText(text, font: font, cameraHeight: cameraHeight, horizontalInset: horizontalInset, animate: animate)
    }

    func applyAccessibilityPreferences() {
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        content.reduceTransparency = reduceTransparency
        glass.style = reduceTransparency ? .regular : .clear
    }
}

private final class MouseNotchContent: NSView {
    private let label = NSTextField(labelWithString: "")
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
        let top = bounds.height - extraTopInset - cameraHeight - 14
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
        needsDisplay = true
    }

    func setText(_ text: String, font: NSFont, cameraHeight: CGFloat, horizontalInset: CGFloat, animate: Bool) {
        textRevision += 1
        let revision = textRevision
        self.cameraHeight = cameraHeight
        self.horizontalInset = horizontalInset
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.lineBreakMode = font.pointSize > 17 ? .byWordWrapping : .byTruncatingTail
        paragraph.alignment = font.pointSize > 17 ? .left : .center
        let attributed = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph
        ])
        let updateText = { [weak self] in
            guard let self, self.textRevision == revision else { return }
            self.label.maximumNumberOfLines = font.pointSize > 17 ? 0 : 1
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
