import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

struct DisplayTapCalibrationView: View {
    @ObservedObject var monitor: DisplayTapMonitor

    var body: some View {
        VStack(spacing: 0) {
            if let session = monitor.calibration {
                Text("Calibrate display taps").font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 14)
                cue(session)
                Text(heading(session))
                    .font(.title2.weight(.semibold))
                    .padding(.top, 12)
                Text(session.message)
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 5)
                if let progress = sampleProgress(session.step) {
                    Text(progress).font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary).padding(.top, 8)
                }
                if session.phase == .tryIt {
                    HStack(spacing: 14) {
                        Button("Redo single taps") { monitor.redoCalibrationSingles() }
                        Button("Redo double taps") { monitor.redoCalibrationDoubles() }
                    }
                    .buttonStyle(.link).font(.callout).padding(.top, 14)
                }
                Spacer(minLength: 18)
                Divider().padding(.bottom, 14)
                HStack {
                    Button("Cancel") { monitor.cancelCalibration() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    if session.phase == .tryIt {
                        Button("Save calibration") { monitor.saveCalibration() }
                            .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    } else if session.phase == .retry {
                        Button("Try again") { monitor.retryCalibrationStep() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(24)
        .frame(width: 416, height: 318)
        .onDisappear { monitor.cancelCalibration() }
    }

    private func cue(_ session: DisplayTapCalibrationSession) -> some View {
        let lit = session.phase == .recording && sampleProgress(session.step) != nil
            || session.phase == .tryIt && session.sandboxEvent != nil
        return ZStack {
            Circle().fill(lit ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.045))
            Circle().strokeBorder(lit ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: lit ? 3 : 1)
            Image(systemName: cueSymbol(session))
                .font(.system(size: 25, weight: .medium))
                .foregroundStyle(lit ? Color.accentColor : Color.secondary)
        }
        .frame(width: 66, height: 66)
        .accessibilityHidden(true)
    }

    private func cueSymbol(_ session: DisplayTapCalibrationSession) -> String {
        if session.phase == .retry { return "arrow.clockwise" }
        if session.phase == .tryIt {
            switch session.sandboxEvent {
            case .singleTap: return "1.circle"
            case .doubleTap: return "2.circle"
            default: return "hand.tap"
            }
        }
        switch session.step {
        case .baseline: return "pause"
        case .single: return "1.circle"
        case .double: return "2.circle"
        case .complete: return "hand.tap"
        }
    }

    private func heading(_ session: DisplayTapCalibrationSession) -> String {
        switch session.phase {
        case .tryIt:
            switch session.sandboxEvent {
            case .singleTap: return "Single tap"
            case .doubleTap: return "Double tap"
            case .firstTapPending: return "Tap detected…"
            case nil: return "Try it"
            }
        case .retry: return "Try that sample again"
        case .preparing: return session.step == .baseline ? "Hold still" : "Get ready"
        case .recording:
            switch session.step {
            case .baseline: return "Hold still"
            case .single: return "Tap the display once"
            case .double: return "Double-tap the display"
            case .complete: return "Try it"
            }
        }
    }

    private func sampleProgress(_ step: DisplayTapCalibration.Step) -> String? {
        switch step {
        case .single(let number): return "Single tap · \(number) of 3"
        case .double(let number): return "Double tap · \(number) of 3"
        case .baseline, .complete: return nil
        }
    }
}
