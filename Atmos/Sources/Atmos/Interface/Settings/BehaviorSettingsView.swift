import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// One place to compare model routes and tune speech capture. Preferences are
/// persisted by AppModel, while each submitted command keeps its chosen mode.
struct BehaviorSettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Behavior & logs").font(.headline)
            VStack(alignment: .leading, spacing: 7) {
                Picker("Chatbot behavior", selection: $model.preferences.behavior) {
                    ForEach(ChatbotBehavior.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                Text(model.preferences.behavior.detail)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Audio sensitivity").font(.callout)
                    Spacer()
                    Text(model.preferences.audioSensitivity, format: .percent.precision(.fractionLength(0)))
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: $model.preferences.audioSensitivity, in: 0...1) {
                    Text("Audio sensitivity")
                } minimumValueLabel: {
                    Text("Lower").font(.caption2)
                } maximumValueLabel: {
                    Text("Higher").font(.caption2)
                }.labelsHidden()
                Text("Higher detects quieter speech; it may also detect more background sound.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Second transcription pass").font(.callout)
                Spacer()
                Toggle("Second transcription pass", isOn: $model.preferences.secondPassEnabled)
                    .labelsHidden().toggleStyle(.switch)
            }
            Text(model.preferences.secondPassEnabled
                 ? "Rechecks the audio before submitting."
                 : "Uses the fast first transcript.")
                .font(.caption).foregroundStyle(.secondary).padding(.top, -10)
            Divider()
            LatestActionTimingView(trace: model.latestCommandTiming)
            StageTimingsView(traces: model.timingTraces)
        }
        .padding(16)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
}
