import AppKit
import QuartzCore

/// The notch is the interface; loading uses a compact, noninteractive dot ring.
enum AtmosOverlayState: Equatable {
    case standby
    case tapPending
    case active
    case transcribing(String)
    case thinking
    case working(String)
    case notice(String)
}

@MainActor
final class AtmosNotchController {
    private let panel = AtmosNotchPanel()
    private let surface = AtmosNotchSurface()
    private var state: AtmosOverlayState = .standby
    private var requestedState: AtmosOverlayState = .standby
    private var suppressed = false
    private var displayTapScreen: NSScreen?
    private var transitionID = 0

    init() {
        panel.contentView = surface
    }

    func show(_ nextState: AtmosOverlayState) {
        requestedState = nextState
        guard !suppressed else { return }
        render(nextState)
    }

    func showTapFeedback() {
        guard !suppressed, requestedState == .standby else { return }
        displayTapScreen = AtmosExpandedMenuGeometry.targetScreen()
        render(.tapPending)
    }

    func endTapFeedback() {
        guard state == .tapPending, !suppressed else { return }
        render(requestedState)
    }

    func setSuppressed(_ value: Bool) {
        guard value != suppressed else { return }
        suppressed = value
        if value {
            transitionID += 1
            panel.orderOut(nil)
            surface.finishThinking(animated: false) {}
            state = .standby
            displayTapScreen = nil
        } else {
            render(requestedState)
        }
    }

    private func render(_ nextState: AtmosOverlayState) {
        guard nextState != state else { return }
        guard let screen = displayTapScreen ?? NSScreen.screens.first ?? NSScreen.main else { return }
        let geometry = AtmosNotchGeometry(screen: screen)
        if nextState == .standby { displayTapScreen = nil }
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

    private func present(_ nextState: AtmosOverlayState, after previousState: AtmosOverlayState,
                         geometry: AtmosNotchGeometry, transition currentTransition: Int,
                         reduceMotion: Bool) {
        let duration = reduceMotion ? 0 : nextState == .tapPending ? 0.12 : 0.30

        if nextState == .standby {
            surface.setText("", font: .systemFont(ofSize: 17), cameraWidth: geometry.cameraWidth,
                            cameraHeight: geometry.cameraHeight,
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

        let presentation = AtmosNotchPresentation(state: nextState, geometry: geometry)
        let wasTranscribing: Bool
        if case .transcribing = previousState { wasTranscribing = true } else { wasTranscribing = false }
        let isTranscribing: Bool
        if case .transcribing = nextState { isTranscribing = true } else { isTranscribing = false }
        surface.setText(presentation.text, font: presentation.font, cameraWidth: geometry.cameraWidth,
                        cameraHeight: geometry.cameraHeight,
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
        surface.prepareResize(to: targetFrame.size, shoulderRadius: AtmosNotchContour.shoulderRadius)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.25, 1)
            panel.animator().setFrame(targetFrame, display: true)
        }
    }

    func hide() { show(.standby) }
}

private final class AtmosNotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Atmos"
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
        setAccessibilityLabel("Atmos voice interface")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Private AppKit appearance hook: clear glass otherwise becomes frosted in
    // this non-key panel. Report active appearance without changing real focus
    // or input routing. If macOS stops consulting this selector, native glass
    // falls back to its normal inactive appearance.
    @objc(_hasActiveAppearance)
    func hasActiveGlassAppearance() -> Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // AppKit otherwise pushes the panel below the menu-bar/notch safe area.
        // Our geometry already anchors it to the physical top edge of the screen.
        frameRect
    }
}

