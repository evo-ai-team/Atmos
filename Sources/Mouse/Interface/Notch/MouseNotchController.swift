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

