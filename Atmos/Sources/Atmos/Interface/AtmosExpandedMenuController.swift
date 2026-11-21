import AppKit
import Combine
import QuartzCore
import SwiftUI

/// A chassis gesture follows the built-in display, including when another
/// monitor owns the menu bar. An external-only setup follows the pointer.
struct AtmosExpandedMenuGeometry {
    let screenFrame: NSRect
    let frame: NSRect
    let collapsedFrame: NSRect
    let topInset: CGFloat

    init(screen: NSScreen, isFullScreen: Bool = false) {
        let bounds = screen.frame
        screenFrame = bounds
        let height = isFullScreen ? bounds.height : bounds.height / 2
        topInset = min(height, max(NSStatusBar.system.thickness, screen.safeAreaInsets.top,
                                   bounds.maxY - screen.visibleFrame.maxY))
        frame = NSRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
        collapsedFrame = NSRect(x: bounds.minX, y: bounds.maxY - 1, width: bounds.width, height: 1)
    }

    static func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        return screens.first { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(id.uint32Value) != 0
        } ?? screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main ?? screens.first
    }
}

@MainActor
final class AtmosExpandedMenuController {
    var onVisibilityChanged: ((Bool) -> Void)?
    private(set) var isVisible = false
    var isFullScreen: Bool { navigation?.isFullScreen == true }
    var isPresenting: Bool { isVisible && !isClosing }
    var isCalibrating: Bool { isPresenting && navigation?.page == .calibration }
    private var isClosing = false
    private var panel: ExpandedMenuPanel?
    private var surface: ExpandedMenuSurface?
    private var navigation: AtmosMenuNavigation?
    private var fullScreenObserver: AnyCancellable?
    private weak var model: AppModel?
    private var screensObserver: NSObjectProtocol?
    private var keyObserver: NSObjectProtocol?
    private var accessibilityObserver: NSObjectProtocol?
    private var globalClick: Any?
    private var localEvents: Any?
    private var previousApp: NSRunningApplication?
    private var transition = 0
    private var slideGeneration = 0
    private var fadeTask: Task<Void, Never>?
    private var afterDismiss: (() -> Void)?

    func show(model: AppModel, page: AtmosMenuPage = .home, isFullScreen requestedFullScreen: Bool? = nil) {
        guard let screen = AtmosExpandedMenuGeometry.targetScreen() else { return }
        let geometry = AtmosExpandedMenuGeometry(screen: screen, isFullScreen: requestedFullScreen ?? isFullScreen)
        if isVisible, let panel, let surface {
            guard afterDismiss == nil else { return }
            if let sheet = panel.attachedSheet {
                sheet.makeKeyAndOrderFront(nil)
                return
            }
            if isClosing {
                model.setMenuPresented(true, reopening: true)
                model.setMenuVoicePageVisible(page == .home)
            }
            navigation?.page = page
            if let requestedFullScreen { navigation?.isFullScreen = requestedFullScreen }
            panel.makeKeyAndOrderFront(nil)
            if isClosing {
                transition += 1
                isClosing = false
                fadeTask?.cancel()
                navigation?.presentationPhase = .concealed
                surface.geometry = geometry
                installMonitors(panel)
                reveal(panel, resizeContent: true)
            }
            return
        }
        transition += 1
        isClosing = false
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let navigation = AtmosMenuNavigation(page: page)
        navigation.isFullScreen = requestedFullScreen ?? false
        self.navigation = navigation
        self.model = model
        model.setMenuPresented(true)
        let panel = ExpandedMenuPanel()
        let view = AtmosExpandedMenuView(model: model, navigation: navigation, perform: { [weak self] action in
            guard let self else { return }
            let target = self.previousApp
            guard !self.isClosing else { return }
            self.afterDismiss = {
                // Restore the command's target if editing activated Atmos.
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
                   let target, !target.isTerminated { _ = target.activate(options: []) }
                action()
            }
            self.dismiss()
        }, dismiss: { [weak self] in self?.dismiss() })
        let surface = ExpandedMenuSurface(content: view, geometry: geometry)
        self.panel = panel
        self.surface = surface
        panel.setFrame(geometry.frame, display: false)
        panel.contentView = surface
        surface.layoutSubtreeIfNeeded()
        surface.setVisibleHeight(geometry.collapsedFrame.height)
        panel.onCancel = { [weak self] in self?.handleEscape() }
        isVisible = true
        // @Published emits before storing the value. Resize on the next main
        // turn so even a Reduce Motion layout sees the new toolbar state.
        fullScreenObserver = navigation.$isFullScreen.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] fullScreen in
            guard let self, !self.isClosing, let panel = self.panel, let surface = self.surface,
                  let screen = panel.screen ?? AtmosExpandedMenuGeometry.targetScreen() else { return }
            let geometry = AtmosExpandedMenuGeometry(screen: screen, isFullScreen: fullScreen)
            guard geometry.frame != surface.geometry.frame else { return }
            surface.geometry = geometry
            if !fullScreen { navigation.isAtFullHeight = false }
            self.fadeOut { [weak self] in self?.reveal(panel, resizeContent: true) }
        }
        onVisibilityChanged?(true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installMonitors(panel)
        reveal(panel, resizeContent: false)
    }

    func dismiss() { close(animated: true) }

    private func handleEscape() {
        guard isPresenting, panel?.attachedSheet == nil else { return }
        if navigation?.page == .calibration {
            navigation?.page = .settings
        } else {
            dismiss()
        }
    }

    func dismissImmediately() {
        afterDismiss = nil
        close(animated: false)
    }

    private func reveal(_ panel: NSPanel, resizeContent: Bool) {
        guard let surface, let navigation else { return }
        animate(panel, to: surface.geometry.frame, duration: 0.46, resizeContent: resizeContent) {
            navigation.isAtFullHeight = navigation.isFullScreen && panel.frame == surface.geometry.screenFrame
            navigation.presentationPhase = .visible
        }
    }

    private func fadeOut(then move: @escaping () -> Void) {
        fadeTask?.cancel()
        stopSlide()
        guard let navigation else { return }
        guard navigation.presentationPhase != .concealed,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            navigation.presentationPhase = .concealed
            move()
            return
        }
        navigation.presentationPhase = .leaving
        fadeTask = Task { @MainActor in
            do { try await Task.sleep(for: MenuTransitionPhase.cascadeDuration) } catch { return }
            navigation.presentationPhase = .concealed
            move()
        }
    }

    private func close(animated: Bool) {
        guard let panel, isVisible, !isClosing || !animated else { return }
        transition += 1
        fadeTask?.cancel()
        stopSlide()
        let current = transition
        isClosing = true
        navigation?.isAtFullHeight = false
        removeMonitors()
        model?.setMenuVoicePageVisible(false)
        model?.displayTaps.cancelCalibration()
        model?.displayTaps.endTest()
        if let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .cancel) }
        let finish = { [weak self, weak panel] in
            guard let self, self.transition == current else { return }
            panel?.orderOut(nil)
            panel?.contentView = nil
            self.isVisible = false
            self.isClosing = false
            self.panel = nil
            self.surface = nil
            self.fullScreenObserver = nil
            self.navigation = nil
            self.previousApp = nil
            self.model?.setMenuPresented(false)
            self.model = nil
            self.onVisibilityChanged?(false)
            let action = self.afterDismiss
            self.afterDismiss = nil
            action?()
        }
        if animated, let geometry = surface?.geometry {
            fadeOut { [weak self] in
                self?.animate(panel, to: geometry.collapsedFrame, duration: 0.37, completion: finish)
            }
        } else { finish() }
    }

    private func stopSlide() {
        slideGeneration += 1
        surface?.freezeSlide()
    }

    private func animate(_ panel: NSPanel, to frame: NSRect, duration: TimeInterval,
                         resizeContent: Bool = false, completion: (() -> Void)? = nil) {
        guard let surface else { return }
        stopSlide()
        let generation = slideGeneration
        let initial = surface.visibleHeight
        let canvasHeight = max(initial, frame.height)
        // All content is concealed during travel. Size the hosting view and the
        // native window once; Core Animation moves the live glass independently.
        if resizeContent { surface.layoutHeight = frame.height }
        func fitWindow(_ height: CGFloat, visible: CGFloat) {
            let size = NSSize(width: frame.width, height: height)
            surface.setFrameSize(size)
            surface.layoutSubtreeIfNeeded()
            surface.setVisibleHeight(visible)
            let rect = NSRect(x: frame.minX, y: frame.maxY - height, width: size.width, height: height)
            if panel.frame != rect { panel.setFrame(rect, display: false) }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || abs(initial - frame.height) < 0.5 {
            fitWindow(frame.height, visible: frame.height)
            completion?()
            return
        }
        fitWindow(canvasHeight, visible: initial)
        surface.slide(from: initial, to: frame.height, duration: duration) { [weak self] in
            guard let self, self.slideGeneration == generation else { return }
            fitWindow(frame.height, visible: frame.height)
            completion?()
        }
    }

    private func installMonitors(_ panel: NSPanel) {
        let click: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: click) { [weak self] event in
            // A global mouse event went to another app, even when its window
            // overlaps this panel on screen. Leave that app's click untouched.
            self?.handleOutsideClick(event)
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: click.union(.keyDown)) { [weak self, weak panel] event in
            guard let self, let panel, NSApp.modalWindow == nil else { return event }
            if event.type == .keyDown {
                if event.window === panel, panel.attachedSheet == nil, event.keyCode == 53 {
                    self.handleEscape()
                    return nil
                }
            } else if let window = event.window, window !== panel, window.parent !== panel, window.sheetParent !== panel,
                      !panel.frame.contains(window.convertPoint(toScreen: event.locationInWindow)) {
                self.handleOutsideClick(event)
            }
            return event
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel, self.panel === panel, self.isVisible, !panel.isKeyWindow,
                      self.navigation?.page != .settings, self.model?.menuMicrophonePermissionPending != true,
                      panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                self.dismiss()
            }
        }
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                guard let screen = AtmosExpandedMenuGeometry.targetScreen() else { self.close(animated: false); return }
                let geometry = AtmosExpandedMenuGeometry(screen: screen, isFullScreen: self.navigation?.isFullScreen == true)
                self.fadeTask?.cancel()
                self.stopSlide()
                self.surface?.geometry = geometry
                self.surface?.layoutHeight = geometry.frame.height
                self.panel?.setFrame(geometry.frame, display: false)
                self.surface?.layoutSubtreeIfNeeded()
                self.surface?.setVisibleHeight(geometry.frame.height)
                self.navigation?.isAtFullHeight = self.isFullScreen
                self.navigation?.presentationPhase = .visible
            }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.surface?.applyAccessibilityPreferences() }
        }
    }

    private func handleOutsideClick(_ event: NSEvent) {
        guard model?.menuMicrophonePermissionPending != true else { return }
        if let modal = NSApp.modalWindow, modal !== panel?.attachedSheet { return }
        if navigation?.page == .settings, Self.isAuthorizationDialog(event) { return }
        dismiss()
    }

    /// macOS hosts Keychain and authorization dialogs in separate processes.
    private static func isAuthorizationDialog(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return false }
        let id = CGWindowID(clamping: cgEvent.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        guard id != kCGNullWindowID,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let pid = rows.first?[kCGWindowOwnerPID as String] as? Int32,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return ["com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
                "com.apple.LocalAuthentication.UIAgent", "com.apple.CoreServicesUIAgent"].contains(bundle)
    }

    private func removeMonitors() {
        if let globalClick { NSEvent.removeMonitor(globalClick); self.globalClick = nil }
        if let localEvents { NSEvent.removeMonitor(localEvents); self.localEvents = nil }
        if let screensObserver { NotificationCenter.default.removeObserver(screensObserver); self.screensObserver = nil }
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver); self.keyObserver = nil }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
            self.accessibilityObserver = nil
        }
    }
}

private final class ExpandedMenuPanel: NSPanel {
    var onCancel: (() -> Void)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Atmos menu"
        setAccessibilityLabel(title)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        // AppKit resets the level when a panel becomes floating. Assign it
        // afterwards so the extended panel stays above the Dock.
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // A menu bar app can have a key panel without an application Edit menu.
    // Route standard editing shortcuts to the same AppKit text editor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if super.performKeyEquivalent(with: event) { return true }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers == .command, let editor = firstResponder as? NSTextView else { return false }
        // Let AppKit handle clipboard export from shared field editors,
        // including the password fields in Settings.
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": editor.selectAll(self)
        case "v": editor.paste(self)
        case "c" where !editor.isFieldEditor: editor.copy(self)
        case "x" where !editor.isFieldEditor: editor.cut(self)
        default: return false
        }
        return true
    }

    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The slide is a translation of a pre-sized live glass surface. Its tint
/// stretches with the exposed body, and a stationary bezel absorbs the edge.
private final class ExpandedMenuSurface: NSView {
    var geometry: AtmosExpandedMenuGeometry { didSet { needsLayout = true } }
    var layoutHeight: CGFloat { didSet { needsLayout = true } }
    private let material = NSView()
    private let glass = NSGlassEffectView()
    private let tint = ExpandedMenuTint()
    private let reflection = CAGradientLayer()
    private let reflectionMask = CAShapeLayer()
    private let controls = NSView()
    private let bezel = NSView()
    private let bezelShade = CAGradientLayer()
    private let bezelMask = CALayer()
    private var restingHeight: CGFloat = 1
    private let slideKey = "Atmos.glassSlide"
    private let host: NSHostingView<AtmosExpandedMenuView>
    private let radius: CGFloat = 32

    init(content: AtmosExpandedMenuView, geometry: AtmosExpandedMenuGeometry) {
        self.geometry = geometry
        layoutHeight = geometry.frame.height
        host = NSHostingView(rootView: content)
        super.init(frame: NSRect(origin: .zero, size: geometry.frame.size))
        host.sizingOptions = []
        host.safeAreaRegions = []
        wantsLayer = true
        layer?.masksToBounds = true

        material.wantsLayer = true
        addSubview(material)
        glass.style = .clear
        material.addSubview(glass)
        let contentView = NSView()
        contentView.wantsLayer = true
        glass.contentView = contentView
        contentView.addSubview(tint)
        // AppKit softens its lighting on an inactive panel. Keep a one-pixel
        // highlight on the lower curve, as on the compact notch.
        reflection.startPoint = CGPoint(x: 0.5, y: 0)
        reflection.endPoint = CGPoint(x: 0.5, y: 1)
        reflectionMask.fillColor = nil
        reflectionMask.strokeColor = NSColor.white.cgColor
        reflection.mask = reflectionMask
        reflection.zPosition = 1
        contentView.layer?.addSublayer(reflection)

        controls.wantsLayer = true
        controls.layer?.masksToBounds = true
        controls.addSubview(host)
        addSubview(controls)
        bezel.wantsLayer = true
        bezelShade.colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1)]
        bezelShade.startPoint = CGPoint(x: 0.5, y: 0)
        bezelShade.endPoint = CGPoint(x: 0.5, y: 1)
        bezelMask.anchorPoint = .zero
        bezelMask.backgroundColor = CGColor(gray: 1, alpha: 1)
        bezelShade.mask = bezelMask
        bezel.layer?.addSublayer(bezelShade)
        addSubview(bezel)
        applyAccessibilityPreferences()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let bar = min(bounds.height, geometry.topInset)
        let layoutBody = max(1, layoutHeight - geometry.topInset)
        let bodyHeight = max(1, bounds.height - bar)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        material.frame = NSRect(x: 0, y: bounds.height - restingHeight, width: bounds.width, height: bounds.height)
        // Clip two physical pixels from each side of the native reflection.
        // Keep the glass bottom exactly on the moving panel edge.
        let scale = window?.backingScaleFactor ?? 1
        let pixel = 1 / scale
        let sideBleed = 2 * pixel
        glass.frame = NSRect(x: -sideBleed, y: 0, width: bounds.width + 2 * sideBleed,
                             height: bounds.height + radius + 2)
        reflection.frame = CGRect(x: 0, y: 0, width: glass.frame.width, height: radius)
        reflectionMask.frame = reflection.bounds
        reflectionMask.contentsScale = scale
        reflectionMask.lineWidth = pixel
        if material.layer?.animation(forKey: slideKey) == nil {
            setCorners(from: restingHeight, to: restingHeight, duration: 0)
        }
        let softEdge = min(18, max(0, bounds.height - bar))
        let shadeHeight = max(1, bar + softEdge)
        bezel.frame = NSRect(x: 0, y: bounds.height - shadeHeight, width: bounds.width, height: shadeHeight)
        bezelShade.frame = bezel.bounds
        bezelShade.locations = [0, NSNumber(value: Double(softEdge / shadeHeight)), 1]
        bezelMask.bounds = CGRect(origin: .zero, size: bounds.size)
        bezelMask.position = CGPoint(x: 0, y: shadeHeight - bounds.height)
        tint.frame = NSRect(x: 0, y: 0, width: glass.frame.width, height: bodyHeight)
        controls.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bar)
        host.frame = NSRect(x: 0, y: controls.bounds.height - layoutBody, width: bounds.width, height: layoutBody)
    }

    var visibleHeight: CGFloat {
        guard let layer = material.layer, layer.animation(forKey: slideKey) != nil,
              let presented = layer.presentation() else { return restingHeight }
        return min(bounds.height, max(1, restingHeight - presented.transform.m42))
    }

    func freezeSlide() {
        guard material.layer?.animation(forKey: slideKey) != nil else { return }
        setVisibleHeight(visibleHeight)
    }

    func setVisibleHeight(_ height: CGFloat) {
        applySlide(from: height, to: height, duration: 0, completion: nil)
    }

    func slide(from start: CGFloat, to end: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        applySlide(from: start, to: end, duration: duration, completion: completion)
    }

    /// Only the final 32 points of travel against the screen bottom straighten
    /// the glass. Match the native material and its bottom highlight in flight.
    private func setCorners(from start: CGFloat, to end: CGFloat, duration: TimeInterval) {
        let screenHeight = geometry.screenFrame.height
        func corner(at height: CGFloat) -> CGFloat { min(radius, max(0, screenHeight - height)) }
        func outline(_ corner: CGFloat) -> CGPath {
            let inset = reflectionMask.lineWidth / 2
            let r = max(0, corner - inset)
            let x = glass.bounds.width - inset
            let k = r * 0.55228475
            let path = CGMutablePath()
            // Keep the same curve elements at radius zero for CA path interpolation.
            path.move(to: CGPoint(x: inset, y: inset + r))
            path.addCurve(to: CGPoint(x: inset + r, y: inset), control1: CGPoint(x: inset, y: inset + r - k),
                          control2: CGPoint(x: inset + r - k, y: inset))
            path.addLine(to: CGPoint(x: x - r, y: inset))
            path.addCurve(to: CGPoint(x: x, y: inset + r), control1: CGPoint(x: x - r + k, y: inset),
                          control2: CGPoint(x: x, y: inset + r - k))
            return path
        }
        let first = corner(at: start), last = corner(at: end)
        reflectionMask.removeAnimation(forKey: slideKey)
        reflectionMask.path = outline(last)
        glass.cornerRadius = first
        guard duration > 0, first != last else {
            glass.cornerRadius = last
            return
        }
        let crossing = (screenHeight - radius - start) / (end - start)
        var radii = [first, last]
        var times: [NSNumber] = [0, 1]
        if crossing > 0 && crossing < 1 {
            radii.insert(radius, at: 1)
            times.insert(NSNumber(value: Double(crossing)), at: 1)
        }
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let native = CAKeyframeAnimation()
        native.values = radii
        native.keyTimes = times
        native.timingFunction = timing
        glass.animations = ["cornerRadius": native]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = timing
            glass.animator().cornerRadius = last
        }
        let highlight = CAKeyframeAnimation(keyPath: "path")
        highlight.values = radii.map(outline)
        highlight.keyTimes = times
        highlight.timingFunction = timing
        highlight.duration = duration
        reflectionMask.add(highlight, forKey: slideKey)
    }

    private func applySlide(from start: CGFloat, to end: CGFloat, duration: TimeInterval, completion: (() -> Void)?) {
        guard let materialLayer = material.layer else { return }
        restingHeight = end
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let completion {
            CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        }
        func transform(_ layer: CALayer, _ from: CATransform3D, _ to: CATransform3D) {
            layer.removeAnimation(forKey: slideKey)
            layer.transform = to
            guard duration > 0 else { return }
            let animation = CABasicAnimation(keyPath: "transform")
            animation.fromValue = NSValue(caTransform3D: from)
            animation.toValue = NSValue(caTransform3D: to)
            animation.duration = duration
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let refresh = Float(window?.screen?.maximumFramesPerSecond ?? 60)
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: max(30, refresh), preferred: max(30, refresh))
            layer.add(animation, forKey: slideKey)
        }
        func offset(_ height: CGFloat) -> CATransform3D {
            CATransform3DMakeTranslation(0, bounds.height - height, 0)
        }
        func shade(_ height: CGFloat) -> CATransform3D {
            // The ramp is pinned to the material's bottom edge.
            let exposed = max(0.01, height - geometry.topInset)
            return CATransform3DMakeScale(1, exposed / max(1, tint.bounds.height), 1)
        }
        material.setFrameOrigin(NSPoint(x: 0, y: bounds.height - end))
        transform(materialLayer, CATransform3DMakeTranslation(0, end - start, 0), CATransform3DIdentity)
        transform(bezelMask, offset(start), offset(end))
        transform(tint.rampLayer, shade(start), shade(end))
        setCorners(from: start, to: end, duration: duration)
        CATransaction.commit()
    }

    func applyAccessibilityPreferences() {
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        tint.reduceTransparency = reduced
        reflection.colors = [CGColor(gray: 1, alpha: reduced ? 0.2 : 0.46), CGColor(gray: 1, alpha: 0)]
    }
}

private final class ExpandedMenuTint: NSView {
    var reduceTransparency = false { didSet { tile.contents = reduceTransparency ? Self.opaqueRamp : Self.glassRamp } }
    let rampLayer = CAReplicatorLayer()
    private let tile = CALayer()
    private static let glassRamp = makeRamp(opaque: false)
    private static let opaqueRamp = makeRamp(opaque: true)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        rampLayer.anchorPoint = .zero
        rampLayer.masksToBounds = true
        tile.contents = Self.glassRamp
        tile.magnificationFilter = .nearest
        tile.minificationFilter = .nearest
        rampLayer.addSublayer(tile)
        layer?.addSublayer(rampLayer)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 1
        let width = CGFloat(Self.glassRamp.width) / scale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rampLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        rampLayer.position = .zero
        tile.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        rampLayer.instanceCount = max(1, Int(ceil(bounds.width / width)))
        rampLayer.instanceTransform = CATransform3DMakeTranslation(width, 0, 0)
        CATransaction.commit()
    }

    /// A single continuous falloff keeps the middle dark and most of the
    /// reveal near the bottom. Dither between adjacent 8-bit values so large
    /// near-black regions do not acquire a horizontal contour on SDR screens.
    private static func makeRamp(opaque: Bool) -> CGImage {
        let thresholds = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let width = 256, height = 1024
        var pixels = [UInt8](repeating: 0, count: width * height * 2)
        for y in 0..<height {
            let progress = Double(y) / Double(height - 1)
            let reveal = pow(progress, 4.5)
            let value = 255 * (opaque ? 0.12 * reveal : 1 - 0.88 * reveal)
            for x in 0..<width {
                let threshold = (Double(thresholds[(y % 4) * 4 + x % 4]) + 0.5) / 16
                let quantized = UInt8(min(255, floor(value + threshold)))
                let offset = (y * width + x) * 2
                pixels[offset] = opaque ? quantized : 0
                pixels[offset + 1] = opaque ? 255 : quantized
            }
        }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 16,
                       bytesPerRow: width * 2, space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)!
    }
}
