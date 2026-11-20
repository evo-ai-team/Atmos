import AppKit
import Combine
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// Owns the motion stream for the visible, signed-in laptop session.
@MainActor
final class DisplayTapMonitor: ObservableObject {
    enum State: Equatable {
        case off, suspended, connecting, ready, unavailable(String)
    }

    @Published private(set) var state: State = .off
    @Published private(set) var testMessage: String?
    @Published private(set) var calibration: DisplayTapCalibrationSession?
    var onGesture: ((DisplayTapRecognizer.Event) -> Void)?
    var onReset: (() -> Void)?
    var onSaveCalibration: ((DisplayTapProfile) -> Void)?

    private let reader = ChassisMotionReader()
    private var recognizer = DisplayTapRecognizer()
    private var threshold = DisplayTapRecognizer.defaultThreshold
    private var profile: DisplayTapProfile?
    private var workflow: DisplayTapCalibrationWorkflow?
    private let uptime: () -> TimeInterval
    private var recognitionStartsAt: TimeInterval = 0
    private var enabled = false
    private var suspensions = Set<String>()
    private var subscriptions = Set<AnyCancellable>()
    private var testTask: Task<Void, Never>?

    init(uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.uptime = uptime
        let workspace = NSWorkspace.shared.notificationCenter
        for (sleep, wake, reason) in [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "system"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "screens"),
            (NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification, "session")
        ] {
            observe(workspace, sleep) { [weak self] in self?.suspend(reason) }
            observe(workspace, wake) { [weak self] in self?.resume(reason) }
        }
        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { [weak self] in self?.suspend("lock") }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { [weak self] in self?.resume("lock") }
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.refresh() }
    }

    func configure(enabled: Bool, threshold: Double, profile: DisplayTapProfile? = nil) {
        if threshold != self.threshold || profile != self.profile {
            self.threshold = threshold
            self.profile = profile
            recognizer = profile.map { DisplayTapRecognizer(profile: $0, thresholdOverride: threshold) }
                ?? DisplayTapRecognizer(threshold: threshold)
            resetRecognition()
        }
        self.enabled = enabled
        refresh()
    }

    func retry() { refresh() }

    func testTaps() {
        guard state == .ready, workflow == nil else { return }
        resetRecognition()
        testTask?.cancel()
        testMessage = "Tap the display once, then twice."
        testTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.endTest()
        }
    }

    func endTest() {
        guard testMessage != nil else { return }
        testTask?.cancel()
        testTask = nil
        testMessage = nil
        resetRecognition()
    }

    func startCalibration() {
        guard state == .ready, workflow == nil else { return }
        endTest()
        resetRecognition()
        let workflow = DisplayTapCalibrationWorkflow(at: uptime())
        self.workflow = workflow
        calibration = workflow.session
    }

    func retryCalibrationStep() {
        guard let workflow, workflow.session.phase == .retry else { return }
        workflow.retryStep(at: uptime())
        calibration = workflow.session
    }

    func redoCalibrationSingles() {
        guard let workflow, workflow.session.phase == .tryIt else { return }
        workflow.redoSingles(at: uptime())
        calibration = workflow.session
    }

    func redoCalibrationDoubles() {
        guard let workflow, workflow.session.phase == .tryIt else { return }
        workflow.redoDoubles(at: uptime())
        calibration = workflow.session
    }

    func saveCalibration() {
        guard let session = workflow?.session, session.phase == .tryIt, let profile = session.profile else { return }
        cancelCalibration()
        onSaveCalibration?(profile)
    }

    func cancelCalibration() {
        guard workflow != nil else { return }
        workflow = nil
        calibration = nil
        // Before the fit exists, a second training tap may still be on its way
        // at the slowest pace the calibration can learn.
        resetRecognition(guardInterval: 0.85)
    }

    func stop() {
        enabled = false
        refresh()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping () -> Void) {
        center.publisher(for: name).receive(on: DispatchQueue.main)
            .sink { _ in action() }.store(in: &subscriptions)
    }

    private func suspend(_ reason: String) {
        suspensions.insert(reason)
        refresh()
    }

    private func resume(_ reason: String) {
        suspensions.remove(reason)
        refresh()
    }

    private func refresh() {
        guard enabled, suspensions.isEmpty, Self.laptopDisplayIsActive, Self.sessionIsUnlocked else {
            disconnect(enabled ? .suspended : .off)
            return
        }
        guard state != .ready, state != .connecting else { return }
        state = .connecting
        do {
            try reader.start(onSample: { [weak self] time, acceleration in
                self?.receive(time: time, acceleration: acceleration)
            }, onFailure: { [weak self] message in
                self?.disconnect(.unavailable(message))
            })
        } catch {
            disconnect(.unavailable(error.localizedDescription))
        }
    }

    private static var laptopDisplayIsActive: Bool {
        NSScreen.screens.contains { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) != 0
        }
    }

    private static var sessionIsUnlocked: Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return (session?["CGSSessionScreenIsLocked"] as? Bool) != true
            && (session?[kCGSessionOnConsoleKey] as? Bool) != false
    }

    private func disconnect(_ next: State) {
        reader.stop()
        cancelCalibration()
        endTest()
        resetRecognition()
        state = next
    }

    private func resetRecognition(guardInterval: TimeInterval = 0.5) {
        recognizer.reset()
        // Ignore buffered reports and the tail of the last practice gesture when
        // changing modes. The next live gesture must start in a fresh quiet interval.
        let settlingTime = max(guardInterval, profile?.doubleTapInterval ?? 0)
        recognitionStartsAt = max(recognitionStartsAt, uptime() + settlingTime)
        onReset?()
    }

    private static let inputTypes: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .leftMouseUp,
                                                    .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]

    private static func hadPhysicalInput(in range: ClosedRange<TimeInterval>) -> Bool {
        // Compare a physical key or click to the impact itself. HID reports may
        // arrive in batches, and a later keypress must not cancel a settled tap.
        let now = ProcessInfo.processInfo.systemUptime
        return inputTypes.contains { type in
            let elapsed = CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: type)
            return range.contains(now - elapsed)
        }
    }

    private static func isDisplayTapCandidate(at onset: TimeInterval) -> Bool {
        !hadPhysicalInput(in: (onset - 0.12)...(onset + 0.12))
    }

    private func receive(time: TimeInterval, acceleration: SIMD3<Double>) {
        guard state == .connecting || state == .ready else { return }
        if state == .connecting { state = .ready }
        if let workflow {
            let now = uptime()
            if workflow.receive(time: time, acceleration: acceleration, deliveredAt: now, hadInputSince: { start in
                Self.hadPhysicalInput(in: start...now)
            }, acceptImpulse: Self.isDisplayTapCandidate(at:)) {
                calibration = workflow.session
            }
            return
        }
        guard time >= recognitionStartsAt else { return }
        let wasPending = recognizer.pendingDeadline != nil
        let events = recognizer.sample(x: acceleration.x, y: acceleration.y, z: acceleration.z, at: time,
                                       shouldAcceptImpulse: Self.isDisplayTapCandidate(at:))
        guard !events.isEmpty else {
            if wasPending, recognizer.pendingDeadline == nil { onReset?() }
            return
        }
        guard Self.sessionIsUnlocked else { resetRecognition(); return }
        for event in events {
            if testMessage != nil {
                switch event {
                case .firstTapPending: testMessage = "Tap detected…"
                case .singleTap: testMessage = "Single tap detected"
                case .doubleTap: testMessage = "Double tap detected"
                }
            } else {
                onGesture?(event)
            }
        }
    }
}
