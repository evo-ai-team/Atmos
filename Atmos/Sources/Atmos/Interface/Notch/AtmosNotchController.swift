import AppKit
import QuartzCore

enum AtmosOverlayState: Equatable {
    case standby
    case tapPending
    case active
    case transcribing(String)
    case thinking
    case working(String)
    case notice(String)
    case answer(String)
    case answerReady(UUID)
}

@MainActor
final class AtmosNotchController {
    var onOpenAnswer: ((UUID) -> Void)?
    private let panel = AtmosNotchPanel()
    private let surface = AtmosNotchSurface()
    private let answerTarget = AtmosAnswerTargetPanel()
    private var pendingAnswer: UUID?
    private var markerAnswer: UUID?
    private var reachedTargetSize = false
    private var state: AtmosOverlayState = .standby
    private var requestedState: AtmosOverlayState = .standby
    private var suppressed = false
    private(set) var dismissedByTap = false
    private var displayTapScreen: NSScreen?
    private var transitionID = 0

    init() {
        panel.contentView = surface
        answerTarget.onPress = { [weak self] in
            guard let self, !self.suppressed, case let .answerReady(id) = self.state,
                  self.pendingAnswer == id else { return }
            self.onOpenAnswer?(id)
        }
    }

    /// The pulse from the first impact belongs to the gesture that is still
    /// being recognized. It does not count as an open notch for that gesture.
    var isPresented: Bool { !suppressed && state != .standby && state != .tapPending }

    func dismissForDisplayTap() {
        dismissedByTap = true
        markerAnswer = nil
        requestedState = .standby
        if !suppressed { render(.standby) }
    }

    func resumeAfterDisplayTap() {
        dismissedByTap = false
    }

    func show(_ nextState: AtmosOverlayState) {
        guard !dismissedByTap else { return }
        requestedState = nextState
        guard !suppressed else { return }
        render(resolvedState)
    }

    /// Work and live words still own the notch while active. Return to the
    /// unread answer when those finish, including after a half-height menu.
    func setPendingAnswer(_ id: UUID?, preservingActivity: Bool = false) {
        guard pendingAnswer != id else { return }
        pendingAnswer = id
        markerAnswer = dismissedByTap ? nil : id
        if id != nil && !preservingActivity {
            switch requestedState {
            case .thinking, .notice, .answer: requestedState = .standby
            default: break
            }
        }
        if !suppressed { render(resolvedState) }
    }

    private var resolvedState: AtmosOverlayState {
        guard !dismissedByTap else { return .standby }
        switch requestedState {
        case .standby, .tapPending, .active:
            return markerAnswer.map(AtmosOverlayState.answerReady) ?? requestedState
        default:
            return requestedState
        }
    }

    func showTapFeedback() {
        guard !suppressed, requestedState == .standby, markerAnswer == nil else { return }
        displayTapScreen = AtmosExpandedMenuGeometry.targetScreen()
        render(.tapPending)
    }

    func endTapFeedback() {
        guard state == .tapPending, !suppressed else { return }
        render(resolvedState)
    }

    func setSuppressed(_ value: Bool) {
        guard value != suppressed else { return }
        suppressed = value
        if value {
            transitionID += 1
            hideAnswerTarget()
            panel.orderOut(nil)
            surface.finishThinking(animated: false) {}
            state = .standby
            displayTapScreen = nil
        } else {
            render(resolvedState)
        }
    }

    private func render(_ nextState: AtmosOverlayState) {
        guard nextState != state else { return }
        guard let screen = displayTapScreen ?? NSScreen.screens.first ?? NSScreen.main else { return }
        let geometry = AtmosNotchGeometry(screen: screen)
        if nextState == .standby { displayTapScreen = nil }
        let previousState = state
        hideAnswerTarget()
        state = nextState
        transitionID += 1
        let currentTransition = transitionID
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let present = { [weak self] in
            guard let self, self.transitionID == currentTransition else { return }
            self.present(nextState, after: previousState, geometry: geometry,
                         transition: currentTransition, reduceMotion: reduceMotion)
        }
        if case .answerReady = nextState {
            present()
        } else if nextState != .thinking, surface.isThinkingVisible {
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
                        horizontalInset: presentation.horizontalInset, wraps: presentation.wraps,
                        centered: presentation.centersText,
                        animate: !reduceMotion && !(wasTranscribing && isTranscribing))
        surface.applyAccessibilityPreferences()
        if nextState == .thinking { surface.startThinking(reduceMotion: reduceMotion) }
        if case .answerReady = nextState {
            surface.showAnswerCheck(reduceMotion: reduceMotion) { [weak self] in self?.updateAnswerTarget() }
        }

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
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.transitionID == currentTransition, case .answerReady = self.state else { return }
                self.reachedTargetSize = true
                self.updateAnswerTarget()
            }
        }
    }

    private func hideAnswerTarget() {
        reachedTargetSize = false
        if answerTarget.parent === panel { panel.removeChildWindow(answerTarget) }
        answerTarget.orderOut(nil)
    }

    private func updateAnswerTarget() {
        guard reachedTargetSize, !suppressed, panel.isVisible, case .answerReady = state,
              let rect = surface.answerCheckRect else { return }
        // A separate non-key window gives WindowServer an exact hit region.
        // Returning nil from a view hit test would still swallow clicks that
        // belong to the app behind a mouse-enabled notch window.
        answerTarget.setFrame(panel.convertToScreen(rect).insetBy(dx: -4, dy: -4), display: true)
        if answerTarget.parent !== panel { panel.addChildWindow(answerTarget, ordered: .above) }
        answerTarget.orderFrontRegardless()
    }

    func hide() { show(.standby) }
}

private final class AtmosAnswerTargetPanel: NSPanel {
    var onPress: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "Atmos answer"
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        collectionBehavior = [.stationary, .ignoresCycle]
        let button = AnswerButton(title: "", target: self, action: #selector(openAnswer))
        button.isBordered = false
        button.refusesFirstResponder = true
        button.toolTip = "Open full answer"
        button.setAccessibilityLabel("Open full answer")
        // WindowServer passes genuinely transparent pixels through. One
        // alpha step keeps the native button reachable around the thin glyph.
        button.wantsLayer = true
        button.layer?.backgroundColor = CGColor(gray: 0, alpha: 1 / 255.0)
        contentView = button
    }

    @objc private func openAnswer() { onPress?() }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    private final class AnswerButton: NSButton {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .pointingHand)
        }
    }
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

