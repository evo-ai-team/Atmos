import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

struct DisplayTapSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: DisplayTapMonitor
    let openCalibration: () -> Void

    private var isCalibrated: Bool { model.preferences.displayTapProfile?.isValid == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isCalibrated {
                Toggle("Display taps", isOn: $model.preferences.displayTapsEnabled)
                    .font(.headline)
                    .toggleStyle(.switch)
                Text("Tap once to activate voice or close the open notch. Tap twice to open the menu, then twice again to close both the menu and notch.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Recalibrate display taps…", action: openCalibration)
                    if model.preferences.displayTapsEnabled && monitor.state == .ready {
                        Button(monitor.testMessage == nil ? "Test taps" : "End test") {
                            if monitor.testMessage == nil { monitor.testTaps() } else { monitor.endTest() }
                        }
                    }
                }
                .controlSize(.small)
                if let message = monitor.testMessage { Text(message).font(.callout) }
            } else {
                Text("Display taps").font(.headline)
                Text("Display taps are off until you record a single tap and a double tap on your MacBook display.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Calibrate display taps…", action: openCalibration)
                    .buttonStyle(.glassProminent)
                    .controlSize(.regular)
            }

            switch monitor.state {
            case .suspended:
                Text("Open and unlock the built-in display to use its motion sensor.").font(.caption)
            case .unavailable(let reason):
                Text(reason).font(.caption)
                if isCalibrated && model.preferences.displayTapsEnabled {
                    Button("Retry sensor", action: monitor.retry).controlSize(.small)
                }
            case .connecting:
                Text("Connecting to the motion sensor…").font(.caption)
            case .ready, .off:
                EmptyView()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .onDisappear { monitor.endTest() }
    }
}
