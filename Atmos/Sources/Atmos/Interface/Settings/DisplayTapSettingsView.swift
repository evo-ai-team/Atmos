import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

struct DisplayTapSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: DisplayTapMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Display taps", isOn: $model.preferences.displayTapsEnabled)
                .font(.headline).toggleStyle(.switch)
            Text("Tap the MacBook display once to speak, or twice to open the Atmos menu.")
                .font(.caption).foregroundStyle(.secondary)
            switch monitor.state {
            case .off: EmptyView()
            case .suspended: Text("Waiting for the built-in display to be awake and unlocked.").font(.caption)
            case .connecting: Text("Connecting to the motion sensor…").font(.caption)
            case .unavailable(let reason):
                Text(reason).font(.caption)
                Button("Retry sensor") { monitor.retry() }.controlSize(.small)
            case .ready:
                HStack {
                    Text("Tap sensitivity").font(.callout)
                    Spacer()
                    if model.preferences.displayTapProfile != nil {
                        Label("Calibrated", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                    }
                }
                // Lower acceleration thresholds register lighter taps.
                Slider(value: Binding(get: { -model.preferences.displayTapThreshold },
                                      set: { model.preferences.displayTapThreshold = -$0 }),
                       in: -AtmosPreferences.displayTapThresholdRange.upperBound ... -AtmosPreferences.displayTapThresholdRange.lowerBound,
                       step: 0.001) {
                    Text("Tap sensitivity")
                } minimumValueLabel: { Text("Firmer").font(.caption2) }
                  maximumValueLabel: { Text("Lighter").font(.caption2) }
                HStack {
                    Button("Calibrate display taps…") { monitor.startCalibration() }
                        .buttonStyle(.glass).controlSize(.small)
                    Button(monitor.testMessage == nil ? "Test taps" : "End test") {
                        if monitor.testMessage == nil { monitor.testTaps() } else { monitor.endTest() }
                    }.controlSize(.small)
                }
                if let message = monitor.testMessage { Text(message).font(.caption) }
            }
        }
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: Binding(get: { monitor.calibration != nil }, set: { presented in
            if !presented { monitor.cancelCalibration() }
        })) {
            DisplayTapCalibrationView(monitor: monitor)
        }
        .onDisappear {
            monitor.endTest()
            monitor.cancelCalibration()
        }
    }
}
