import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

struct DisplayTapCalibrationView: View {
    @ObservedObject var monitor: DisplayTapMonitor
    let isCurrent: Bool
    let back: () -> Void
    @Environment(\.menuTransition) private var phase
    @State private var lastSession: DisplayTapCalibrationSession?

    var body: some View {
        // Cancellation releases the sensor immediately. Keep the last recording
        // visible while the page fades back to Settings or the menu closes.
        let leaving = !isCurrent || phase == .leaving
        let session = monitor.calibration ?? (leaving ? lastSession : nil)
        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Calibrate display taps").font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Click Record, then tap your MacBook display when prompted.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                }
                .atmosMenuElement(0)
                if let session {
                    VStack(spacing: 0) {
                        recordingRow(.single, session: session, sensorReady: monitor.state == .ready || leaving)
                            .atmosMenuElement(1)
                        Divider().atmosMenuElement(2)
                        recordingRow(.double, session: session, sensorReady: monitor.state == .ready || leaving)
                            .atmosMenuElement(2)
                    }
                } else {
                    sensorStatus.atmosMenuElement(1)
                }
                HStack {
                    Button("Cancel", action: back)
                        .buttonStyle(.glass)
                    Spacer()
                    Button("Save and enable") {
                        monitor.saveCalibration()
                        back()
                    }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(isCurrent && phase == .visible ? .defaultAction : nil)
                    .disabled(session?.phase != .complete)
                }
                .atmosMenuElement(3)
            }
            .frame(maxWidth: 500, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .onReceive(monitor.$calibration) { if let session = $0 { lastSession = session } }
        .onChange(of: monitor.state) { _, state in
            switch state {
            case .unavailable, .suspended: lastSession = nil
            default: break
            }
        }
    }

    @ViewBuilder private var sensorStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch monitor.state {
            case .suspended:
                Text("Open and unlock the built-in display to use its motion sensor.")
            case .unavailable(let reason):
                Text(reason)
            case .connecting:
                Text("Connecting to the motion sensor…")
            case .off, .ready:
                Text("Reconnect the motion sensor to record display taps.")
            }
            Button("Retry sensor", action: monitor.startCalibration)
                .buttonStyle(.glass)
                .disabled(monitor.state == .connecting)
        }
        .font(.callout)
    }

    private func recordingRow(_ step: DisplayTapCalibration.Step, session: DisplayTapCalibrationSession, sensorReady: Bool) -> some View {
        let single = step == .single
        let title = single ? "Single tap" : "Double tap"
        let recorded = session.step == .complete || (single && session.step == .double)
        let current = session.step == step
        let capturing = session.phase == .preparing || session.phase == .recording
        let buttonTitle = recorded ? "Record again" : current && session.phase == .retry ? "Retry" : "Record"
        let description = single ? "Activates voice or closes the open notch." : "Opens the menu or closes the menu and notch."

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if recorded {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .accessibilityLabel("Recorded")
                    }
                }
                if current && !sensorReady {
                    Text("Connecting to the motion sensor…").font(.callout)
                } else if current && (capturing || session.phase == .retry) {
                    Text(session.message)
                        .font(.callout.weight(session.phase == .recording ? .semibold : .regular))
                        .foregroundStyle(session.phase == .recording ? Color.accentColor : Color.primary)
                } else {
                    Text(description).font(.callout).foregroundStyle(.white.opacity(0.82))
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)
            if current && capturing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(session.phase == .preparing ? "Preparing to record" : "Recording")
            } else {
                Button(buttonTitle) {
                    if recorded {
                        if single { monitor.redoCalibrationSingle() } else { monitor.redoCalibrationDouble() }
                    } else {
                        monitor.recordCalibrationStep()
                    }
                }
                .buttonStyle(.glass)
                .accessibilityLabel(recorded ? "Record \(title.lowercased()) again" : "\(buttonTitle) \(title.lowercased())")
                .disabled(!sensorReady || capturing || (!current && !recorded))
            }
        }
        .frame(minHeight: 47)
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }
}
