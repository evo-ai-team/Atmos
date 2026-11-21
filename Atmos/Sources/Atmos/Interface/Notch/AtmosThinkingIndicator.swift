import AppKit
import QuartzCore

/// A compact, text-free activity ring. Core Animation owns its animation clock,
/// so resizing the notch does not restart the orbit or the traveling pulse.
@MainActor
final class AtmosThinkingIndicator: NSView {
    static var preferredSide: CGFloat { Design.side }

    private enum State {
        case hidden, running, exiting, drawingCheck, check
    }

    private enum Design {
        static let count = 6
        static let side: CGFloat = 30
        static let diameter: CGFloat = 4.5
        static let orbitRadius: CGFloat = 10.5
        static let orbitDuration: CFTimeInterval = 11
        static let pulseDuration: CFTimeInterval = 1.2
        static let appearanceDuration: CFTimeInterval = 0.4
        static let exitStagger: CFTimeInterval = 0.03
        static let exitDuration: CFTimeInterval = 0.105
    }

    private struct Dot {
        let envelope: CALayer
        let bead: CALayer
    }

    private let orbit = CALayer()
    private let check = CAShapeLayer()
    private var dots: [Dot] = []
    private var state: State = .hidden
    private var reduceMotion = false
    private var generation = 0
    private var exitCompletion: (() -> Void)?
    private var checkCompletion: (() -> Void)?
    private var minimumOrbitTask: Task<Void, Never>?
    private var startedAt: CFTimeInterval = 0

    /// Includes the brief sequential exit, so the surrounding notch can wait
    /// for the final bead to disappear before displaying its action label.
    var isVisible: Bool { state != .hidden }
    var hasFinishedCheck: Bool { state == .check }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        orbit.masksToBounds = false
        orbit.bounds = CGRect(x: 0, y: 0, width: Design.side, height: Design.side)
        layer?.addSublayer(orbit)
        check.bounds = orbit.bounds
        let path = CGMutablePath()
        path.move(to: Self.checkStart)
        path.addLine(to: CGPoint(x: 12, y: 9))
        path.addLine(to: CGPoint(x: 24, y: 22))
        check.path = path
        check.fillColor = nil
        check.strokeColor = NSColor.white.cgColor
        check.lineWidth = 3.4
        check.lineCap = .round
        check.lineJoin = .round
        check.isHidden = true
        layer?.addSublayer(check)
        dots = (0..<Design.count).map { _ in Self.makeDot() }
        for (index, dot) in dots.enumerated() {
            dot.envelope.position = Self.position(for: index)
            orbit.addSublayer(dot.envelope)
        }
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Processing request")
        updateContentsScale()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbit.position = CGPoint(x: bounds.midX, y: bounds.midY)
        check.position = orbit.position
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateContentsScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateContentsScale()
    }

    func start(reduceMotion: Bool) {
        if state == .running, self.reduceMotion == reduceMotion { return }

        let wasHidden = state == .hidden || state == .check || state == .drawingCheck
        let previousRotation = rotation(of: orbit)
        let starts = dots.map { dot in
            (scale(of: dot.envelope) * scale(of: dot.bead),
             dot.envelope.presentation()?.opacity ?? dot.envelope.opacity,
             dot.envelope.presentation()?.position ?? dot.envelope.position)
        }
        generation += 1
        minimumOrbitTask?.cancel()
        checkCompletion = nil
        exitCompletion = nil
        state = .running
        startedAt = CACurrentMediaTime()
        self.reduceMotion = reduceMotion
        isHidden = false
        setAccessibilityElement(true)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        check.removeAllAnimations()
        check.isHidden = true
        orbit.removeAllAnimations()
        orbit.transform = reduceMotion ? CATransform3DIdentity
            : CATransform3DMakeRotation(previousRotation, 0, 0, 1)
        for (index, dot) in dots.enumerated() {
            dot.envelope.removeAllAnimations()
            dot.bead.removeAllAnimations()
            dot.envelope.transform = CATransform3DIdentity
            dot.bead.transform = CATransform3DIdentity
            dot.envelope.opacity = 1
            dot.envelope.position = Self.position(for: index)
        }

        if !reduceMotion {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = previousRotation
            rotation.toValue = previousRotation - 2 * .pi
            rotation.duration = Design.orbitDuration
            rotation.repeatCount = .infinity
            rotation.timingFunction = CAMediaTimingFunction(name: .linear)
            orbit.add(rotation, forKey: "orbit")

            let now = orbit.convertTime(CACurrentMediaTime(), from: nil)
            for (index, dot) in dots.enumerated() {
                let spread = CABasicAnimation(keyPath: "position")
                spread.fromValue = wasHidden
                    ? CGPoint(x: Design.side / 2, y: Design.side / 2) : starts[index].2
                spread.toValue = Self.position(for: index)
                spread.duration = Design.appearanceDuration
                spread.timingFunction = CAMediaTimingFunction(name: .easeOut)

                let appear = CABasicAnimation(keyPath: "transform.scale")
                appear.fromValue = wasHidden ? 0.001 : starts[index].0
                appear.toValue = 1
                appear.duration = Design.appearanceDuration
                appear.timingFunction = CAMediaTimingFunction(name: .easeOut)

                let opacity = CABasicAnimation(keyPath: "opacity")
                opacity.fromValue = wasHidden ? 0 : starts[index].1
                opacity.toValue = 1
                opacity.duration = Design.appearanceDuration

                let entrance = CAAnimationGroup()
                entrance.animations = [spread, appear, opacity]
                entrance.duration = Design.appearanceDuration
                dot.envelope.add(entrance, forKey: "appearance")

                // Adjacent pulses overlap: the next bead grows while the
                // previous one settles. The remainder of the cycle is at rest.
                let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
                pulse.values = [1, 1.5, 1, 1]
                pulse.keyTimes = [0, 0.14, 0.36, 1]
                pulse.timingFunctions = [
                    CAMediaTimingFunction(name: .easeInEaseOut),
                    CAMediaTimingFunction(name: .easeInEaseOut),
                    CAMediaTimingFunction(name: .linear)
                ]
                pulse.duration = Design.pulseDuration
                pulse.beginTime = now + Design.appearanceDuration
                    + Double(index) * Design.pulseDuration / Double(Design.count)
                pulse.repeatCount = .infinity
                dot.bead.add(pulse, forKey: "pulse")
            }
        }
        CATransaction.commit()
    }

    func finish(animated: Bool, completion: @escaping () -> Void) {
        guard state != .hidden else {
            completion()
            return
        }
        if state == .check || state == .drawingCheck {
            stopImmediately()
            completion()
            return
        }

        // Transcript updates can arrive several times during the exit. Keep
        // its animation clock and deliver only the latest requested transition.
        exitCompletion = completion
        if state == .exiting {
            if !animated { completeExit(generation: generation) }
            return
        }
        generation += 1
        let exitGeneration = generation
        state = .exiting
        guard animated && !reduceMotion else {
            completeExit(generation: exitGeneration)
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in
                self?.completeExit(generation: exitGeneration)
            }
        }
        for (index, dot) in dots.enumerated() {
            let currentScale = scale(of: dot.envelope) * scale(of: dot.bead)
            let currentOpacity = dot.envelope.presentation()?.opacity ?? dot.envelope.opacity
            let currentPosition = dot.envelope.presentation()?.position ?? dot.envelope.position
            dot.envelope.removeAllAnimations()
            dot.bead.removeAllAnimations()
            dot.bead.transform = CATransform3DIdentity
            dot.envelope.transform = CATransform3DMakeScale(0.001, 0.001, 1)
            dot.envelope.opacity = 0
            dot.envelope.position = currentPosition

            let delay = Double(index) * Design.exitStagger
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = currentScale
            shrink.toValue = 0.001
            shrink.beginTime = delay
            shrink.duration = Design.exitDuration
            shrink.fillMode = .backwards
            shrink.timingFunction = CAMediaTimingFunction(name: .easeIn)

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = currentOpacity
            fade.toValue = 0
            fade.beginTime = delay
            fade.duration = Design.exitDuration
            fade.fillMode = .backwards

            let exit = CAAnimationGroup()
            exit.animations = [shrink, fade]
            exit.duration = delay + Design.exitDuration
            dot.envelope.add(exit, forKey: "exit")
        }
        CATransaction.commit()
    }

    func stopImmediately() {
        generation += 1
        minimumOrbitTask?.cancel()
        minimumOrbitTask = nil
        checkCompletion = nil
        exitCompletion = nil
        state = .hidden
        isHidden = true
        check.removeAllAnimations()
        check.isHidden = true
        orbit.removeAllAnimations()
        dots.forEach {
            $0.envelope.removeAllAnimations()
            $0.bead.removeAllAnimations()
        }
    }

    private static let checkStart = CGPoint(x: 6, y: 15)

    func showAnswerCheck(reduceMotion: Bool, completion: @escaping () -> Void) {
        if state == .check { completion(); return }
        checkCompletion = completion
        if state == .drawingCheck { return }

        let wasRunning = state == .running
        let hasRing = wasRunning || state == .exiting
        generation += 1
        let expected = generation
        exitCompletion = nil
        state = .drawingCheck
        isHidden = false
        // The separate checkmark button supplies the accessible action.
        setAccessibilityElement(false)
        guard hasRing && !reduceMotion else { finishCheck(generation: expected); return }

        // Fast replies can arrive before the ring has spread out. Give that
        // entrance time to become visible before gathering its actual beads.
        let wait = wasRunning ? Design.appearanceDuration - (CACurrentMediaTime() - startedAt) : 0
        if wait > 0 {
            minimumOrbitTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                guard let self, self.generation == expected else { return }
                self.mergeIntoCheck(generation: expected)
            }
        } else {
            mergeIntoCheck(generation: expected)
        }
    }

    private func mergeIntoCheck(generation expected: Int) {
        let angle = rotation(of: orbit)
        let center = CGPoint(x: Design.side / 2, y: Design.side / 2)
        let mergeDuration = 0.29
        let drawDelay = mergeDuration + 0.08
        let drawDuration = 0.30
        let now = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            Task { @MainActor in self?.finishCheck(generation: expected) }
        }
        orbit.removeAllAnimations()
        orbit.transform = CATransform3DIdentity
        for (index, dot) in dots.enumerated() {
            let displayed = dot.envelope.presentation() ?? dot.envelope
            let dx = displayed.position.x - center.x, dy = displayed.position.y - center.y
            let position = CGPoint(x: center.x + dx * cos(angle) - dy * sin(angle),
                                   y: center.y + dx * sin(angle) + dy * cos(angle))
            let startingScale = scale(of: dot.envelope) * scale(of: dot.bead)
            let startingOpacity = displayed.opacity
            dot.envelope.removeAllAnimations()
            dot.bead.removeAllAnimations()
            dot.bead.transform = CATransform3DIdentity
            dot.envelope.transform = CATransform3DIdentity
            dot.envelope.position = Self.checkStart
            dot.envelope.opacity = 0
            let gather = CABasicAnimation(keyPath: "position")
            gather.fromValue = position
            gather.toValue = Self.checkStart
            gather.duration = mergeDuration
            gather.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            let shrink = CABasicAnimation(keyPath: "transform.scale")
            shrink.fromValue = startingScale
            shrink.toValue = check.lineWidth / Design.diameter
            shrink.duration = mergeDuration
            shrink.fillMode = .forwards
            let hold = CAKeyframeAnimation(keyPath: "opacity")
            hold.values = [startingOpacity, 1, 1, 0]
            hold.keyTimes = [0, 0.5, 0.98, 1]
            hold.duration = index == 0 ? drawDelay + drawDuration : mergeDuration
            var animations: [CAAnimation] = [gather, shrink, hold]
            if index == 0 {
                let tip = CAKeyframeAnimation(keyPath: "position")
                tip.path = check.path
                tip.calculationMode = .paced
                tip.beginTime = drawDelay
                tip.duration = drawDuration
                animations.append(tip)
            }
            let group = CAAnimationGroup()
            group.animations = animations
            group.beginTime = dot.envelope.convertTime(now, from: nil)
            group.duration = hold.duration
            dot.envelope.add(group, forKey: "gatherAndTrace")
        }
        check.isHidden = false
        check.strokeEnd = 1
        let trace = CABasicAnimation(keyPath: "strokeEnd")
        trace.fromValue = 0
        trace.toValue = 1
        trace.fillMode = .backwards
        trace.beginTime = check.convertTime(now, from: nil) + drawDelay
        trace.duration = drawDuration
        trace.timingFunction = CAMediaTimingFunction(name: .linear)
        check.add(trace, forKey: "trace")
        CATransaction.commit()
    }

    private func finishCheck(generation expected: Int) {
        guard expected == generation, state == .drawingCheck else { return }
        state = .check
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbit.removeAllAnimations()
        for dot in dots {
            dot.envelope.removeAllAnimations()
            dot.bead.removeAllAnimations()
            dot.envelope.opacity = 0
        }
        check.removeAllAnimations()
        check.strokeEnd = 1
        check.isHidden = false
        CATransaction.commit()
        let completion = checkCompletion
        checkCompletion = nil
        completion?()
    }

    private func completeExit(generation expectedGeneration: Int) {
        guard generation == expectedGeneration, state == .exiting else { return }
        let completion = exitCompletion
        stopImmediately()
        completion?()
    }

    private func scale(of layer: CALayer) -> CGFloat {
        let source = layer.presentation() ?? layer
        return (source.value(forKeyPath: "transform.scale") as? NSNumber)?.doubleValue ?? 1
    }

    private func rotation(of layer: CALayer) -> CGFloat {
        let source = layer.presentation() ?? layer
        return (source.value(forKeyPath: "transform.rotation.z") as? NSNumber)?.doubleValue ?? 0
    }

    private func updateContentsScale() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        func update(_ layer: CALayer) {
            layer.contentsScale = scale
            layer.sublayers?.forEach(update)
        }
        if let layer { update(layer) }
    }

    private static func position(for index: Int) -> CGPoint {
        // AppKit's unflipped coordinates put +y above the center. The orbit
        // rotates during the outward entrance as well as the steady pulse.
        let angle = CGFloat.pi / 2 - CGFloat(index) * 2 * .pi / CGFloat(Design.count)
        return CGPoint(x: Design.side / 2 + Design.orbitRadius * cos(angle),
                       y: Design.side / 2 + Design.orbitRadius * sin(angle))
    }

    private static func makeDot() -> Dot {
        let rect = CGRect(x: 0, y: 0, width: Design.diameter, height: Design.diameter)
        let envelope = CALayer()
        envelope.bounds = rect
        let bead = CALayer()
        bead.frame = rect
        bead.backgroundColor = NSColor.white.cgColor
        bead.cornerRadius = Design.diameter / 2
        bead.shadowColor = NSColor.white.cgColor
        // A centered, diffuse halo softens each dot without blurring its core.
        // It follows the bead's pulse and needs no extra animation or filter.
        bead.shadowOpacity = 0.48
        bead.shadowRadius = 3.2
        bead.shadowOffset = .zero
        bead.shadowPath = CGPath(ellipseIn: rect, transform: nil)
        envelope.addSublayer(bead)

        return Dot(envelope: envelope, bead: bead)
    }
}
