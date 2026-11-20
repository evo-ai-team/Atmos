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
    private var resizeTask: Task<Void, Never>?

    func show(model: AppModel, page: AtmosMenuPage = .home) {
        guard let screen = AtmosExpandedMenuGeometry.targetScreen() else { return }
        let geometry = AtmosExpandedMenuGeometry(screen: screen, isFullScreen: navigation?.isFullScreen == true)
        if isVisible, let panel, let surface {
            if let sheet = panel.attachedSheet {
                sheet.makeKeyAndOrderFront(nil)
                return
            }
            if isClosing {
                model.setMenuPresented(true)
                model.setMenuVoicePageVisible(page == .home)
            }
            navigation?.page = page
            panel.makeKeyAndOrderFront(nil)
            if isClosing {
                transition += 1
                isClosing = false
                panel.ignoresMouseEvents = false
                surface.geometry = geometry
                installMonitors(panel)
                animate(panel, to: geometry.frame, duration: 0.32, resizeContent: true)
            }
            return
        }
        transition += 1
        isClosing = false
        let frontmost = NSWorkspace.shared.frontmostApplication
        previousApp = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmost
        let navigation = AtmosMenuNavigation(page: page)
        self.navigation = navigation
        self.model = model
        model.setMenuPresented(true)
        let panel = ExpandedMenuPanel()
        let view = AtmosExpandedMenuView(model: model, navigation: navigation, perform: { [weak self] action in
            guard let self else { return }
            let target = self.previousApp
            self.close(animated: false)
            // A native panel normally preserves the foreground app. Restore it
            // only if Atmos acquired activation while editing the command.
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
               let target, !target.isTerminated { _ = target.activate(options: []) }
            action()
        }, dismiss: { [weak self] in self?.dismiss() })
        let surface = ExpandedMenuSurface(content: view, geometry: geometry)
        self.panel = panel
        self.surface = surface
        panel.contentView = surface
        panel.setFrame(geometry.collapsedFrame, display: false)
        surface.layoutSubtreeIfNeeded()
        panel.onCancel = { [weak self, weak panel] in
            if panel?.attachedSheet == nil { self?.dismiss() }
        }
        isVisible = true
        // @Published emits before storing the value. Resize on the next main
        // turn so even a Reduce Motion layout sees the new toolbar state.
        fullScreenObserver = navigation.$isFullScreen.dropFirst().receive(on: DispatchQueue.main).sink { [weak self] fullScreen in
            guard let self, !self.isClosing, let panel = self.panel, let surface = self.surface,
                  let screen = panel.screen ?? AtmosExpandedMenuGeometry.targetScreen() else { return }
            let geometry = AtmosExpandedMenuGeometry(screen: screen, isFullScreen: fullScreen)
            surface.geometry = geometry
            self.animate(panel, to: geometry.frame, duration: 0.34, resizeContent: true)
        }
        onVisibilityChanged?(true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        installMonitors(panel)
        animate(panel, to: geometry.frame, duration: 0.32)
    }

    func dismiss() { close(animated: true) }

    func dismissImmediately() { close(animated: false) }

    private func close(animated: Bool) {
        guard let panel, isVisible, !isClosing || !animated else { return }
        transition += 1
        resizeTask?.cancel()
        let current = transition
        isClosing = true
        removeMonitors()
        model?.setMenuVoicePageVisible(false)
        model?.displayTaps.cancelCalibration()
        model?.displayTaps.endTest()
        if let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .cancel) }
        panel.ignoresMouseEvents = true
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
        }
        if animated, let geometry = surface?.geometry {
            animate(panel, to: geometry.collapsedFrame, duration: 0.20, completion: finish)
        } else { finish() }
    }

    private func animate(_ panel: NSPanel, to frame: NSRect, duration: TimeInterval,
                         resizeContent: Bool = false, completion: (() -> Void)? = nil) {
        resizeTask?.cancel()
        guard let surface else { return }
        let initialLayoutHeight = surface.layoutHeight
        func apply(_ step: NSRect, layoutHeight: CGFloat) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            if resizeContent { surface.layoutHeight = layoutHeight }
            surface.setFrameSize(step.size)
            surface.layoutSubtreeIfNeeded()
            panel.setFrame(step, display: true)
            CATransaction.commit()
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            apply(frame, layoutHeight: frame.height)
            completion?()
            return
        }
        // AppKit's animated window resize can publish the new window bounds
        // before its layer-backed content has been redrawn. Advance both on
        // the same tick so contraction never reveals the desktop above the bar.
        let initial = panel.frame.height
        let refresh = max(30, min(120, panel.screen?.maximumFramesPerSecond ?? 60))
        let scale = panel.backingScaleFactor
        let started = CACurrentMediaTime()
        resizeTask = Task { @MainActor in
            while !Task.isCancelled {
                let progress = min(1, (CACurrentMediaTime() - started) / duration)
                let remaining = 1 - progress
                let interpolated = frame.height + (initial - frame.height) * remaining * remaining * remaining
                let height = progress == 1 ? frame.height : (interpolated * scale).rounded() / scale
                let step = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
                let layoutHeight = frame.height + (initialLayoutHeight - frame.height) * remaining * remaining * remaining
                if panel.frame != step || (resizeContent && surface.layoutHeight != layoutHeight) {
                    apply(step, layoutHeight: layoutHeight)
                }
                if progress == 1 { completion?(); return }
                do { try await Task.sleep(for: .seconds(1 / Double(refresh))) } catch { return }
            }
        }
    }

    private func installMonitors(_ panel: NSPanel) {
        let click: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClick = NSEvent.addGlobalMonitorForEvents(matching: click) { [weak self, weak panel] event in
            guard let self, let panel, panel.attachedSheet == nil, NSApp.modalWindow == nil,
                  !panel.frame.contains(NSEvent.mouseLocation) else { return }
            // A first-use microphone prompt belongs to macOS and takes clicks
            // outside the panel while the composer waits for the answer.
            if self.model?.menuMicrophonePermissionPending == true { return }
            if self.navigation?.page == .settings, Self.isSystemSettingsInteraction(event) { return }
            self.close(animated: false)
        }
        localEvents = NSEvent.addLocalMonitorForEvents(matching: click.union(.keyDown)) { [weak self, weak panel] event in
            guard let self, let panel, panel.attachedSheet == nil, NSApp.modalWindow == nil else { return event }
            if event.type == .keyDown {
                if event.window === panel, event.keyCode == 53 { self.dismiss(); return nil }
            } else if self.navigation?.page != .settings, let window = event.window,
                      window !== panel, window.parent !== panel, window.sheetParent !== panel {
                self.close(animated: false)
            }
            return event
        }
        keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification,
            object: panel, queue: .main) { [weak self, weak panel] _ in
            Task { @MainActor in
                guard let self, let panel, self.panel === panel, self.isVisible, !panel.isKeyWindow,
                      self.navigation?.page != .settings, self.model?.menuMicrophonePermissionPending != true,
                      panel.attachedSheet == nil, NSApp.modalWindow == nil else { return }
                self.close(animated: false)
            }
        }
        screensObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible else { return }
                guard let screen = AtmosExpandedMenuGeometry.targetScreen() else { self.close(animated: false); return }
                let geometry = AtmosExpandedMenuGeometry(screen: screen, isFullScreen: self.navigation?.isFullScreen == true)
                self.resizeTask?.cancel()
                self.surface?.geometry = geometry
                self.surface?.layoutHeight = geometry.frame.height
                self.panel?.setFrame(geometry.frame, display: true)
            }
        }
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.surface?.applyAccessibilityPreferences() }
        }
    }

    /// Permission and Keychain dialogs live outside Atmos. Let a click in one
    /// of those windows finish while the Settings page retains its place.
    private static func isSystemSettingsInteraction(_ event: NSEvent) -> Bool {
        guard let cgEvent = event.cgEvent else { return false }
        let id = CGWindowID(clamping: cgEvent.getIntegerValueField(.mouseEventWindowUnderMousePointer))
        guard id != kCGNullWindowID,
              let rows = CGWindowListCopyWindowInfo(.optionIncludingWindow, id) as? [[String: Any]],
              let pid = rows.first?[kCGWindowOwnerPID as String] as? Int32,
              let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier else { return false }
        return ["com.apple.systempreferences", "com.apple.SecurityAgent", "com.apple.UserNotificationCenter",
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

/// The window clips the glass at its moving lower edge. A separate layout
/// height positions the controls and tint during a reveal or full-screen resize.
private final class ExpandedMenuSurface: NSView {
    var geometry: AtmosExpandedMenuGeometry { didSet { needsLayout = true } }
    var layoutHeight: CGFloat { didSet { needsLayout = true } }
    private let materialClip = NSView()
    private let glass = NSGlassEffectView()
    private let tint = ExpandedMenuTint()
    private let controls = NSView()
    private let bezel = NSView()
    private let host: NSHostingView<AtmosExpandedMenuView>
    private let radius: CGFloat = 32

    init(content: AtmosExpandedMenuView, geometry: AtmosExpandedMenuGeometry) {
        self.geometry = geometry
        layoutHeight = geometry.frame.height
        host = NSHostingView(rootView: content)
        super.init(frame: geometry.collapsedFrame)
        host.sizingOptions = []
        host.safeAreaRegions = []
        wantsLayer = true
        layer?.masksToBounds = true

        materialClip.wantsLayer = true
        materialClip.layer?.masksToBounds = true
        materialClip.layer?.cornerCurve = .continuous
        materialClip.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        addSubview(materialClip)
        glass.style = .clear
        glass.cornerRadius = 0
        materialClip.addSubview(glass)
        // Keep the black tint above the glass's own lighting at the bezel.
        materialClip.addSubview(tint)

        controls.wantsLayer = true
        controls.layer?.masksToBounds = true
        controls.addSubview(host)
        addSubview(controls)
        bezel.wantsLayer = true
        bezel.layer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        addSubview(bezel)
        applyAccessibilityPreferences()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let bar = min(bounds.height, geometry.topInset)
        let bodyHeight = max(1, layoutHeight - geometry.topInset)
        materialClip.frame = bounds
        // Round the floating lower edge. As the panel meets the bottom of the
        // display, its corners straighten to cover the last physical pixels.
        materialClip.layer?.cornerRadius = min(radius, max(0, geometry.screenFrame.height - bounds.height))
        // Liquid Glass adds a native specular rim. Keep its four boundaries
        // outside the clip, including when the lower edge moves during resize.
        glass.frame = materialClip.bounds.insetBy(dx: -radius, dy: -radius)
        bezel.frame = NSRect(x: 0, y: bounds.maxY - bar, width: bounds.width, height: bar)
        tint.frame = NSRect(x: 0, y: bounds.maxY - bar - bodyHeight, width: bounds.width, height: bodyHeight)
        controls.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - bar)
        host.frame = NSRect(x: 0, y: controls.bounds.height - bodyHeight, width: bounds.width, height: bodyHeight)
    }

    func applyAccessibilityPreferences() {
        tint.reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }
}

private final class ExpandedMenuTint: NSView {
    var reduceTransparency = false { didSet { needsDisplay = true } }
    private static let glassRamp = makeRamp(opaque: false)
    private static let opaqueRamp = makeRamp(opaque: true)

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, bounds.height > 0 else { return }
        let ramp = reduceTransparency ? Self.opaqueRamp : Self.glassRamp
        let scale = window?.backingScaleFactor ?? 1
        // Repeat only across the width. One complete ramp spans the menu body.
        context.interpolationQuality = .none
        let tile = CGRect(x: 0, y: 0, width: CGFloat(ramp.width) / scale, height: bounds.height)
        context.draw(ramp, in: tile, byTiling: true)
    }

    /// A single continuous falloff keeps the middle dark and most of the
    /// reveal near the bottom. Dither between adjacent 8-bit values so large
    /// near-black regions do not acquire a horizontal contour on SDR screens.
    private static func makeRamp(opaque: Bool) -> CGImage {
        let thresholds = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
        let width = 16, height = 2048
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
