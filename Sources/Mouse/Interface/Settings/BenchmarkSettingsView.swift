import AppKit
import SwiftUI

// TESTING: Remove this view and its MouseView hook with the benchmark feature.
// Trials use the normal command input, model route, and execution pipeline.
struct BenchmarkSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Benchmark", isExpanded: $expanded) {
            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Enable benchmark trials", isOn: Binding(
                        get: { model.benchmarkEnabled },
                        set: { model.setBenchmarkEnabled($0) }
                    ))
                    .toggleStyle(.switch)

                    Text("Pauses the microphone and returns to Settings after each trial. Choose Chatbot behavior above, then use Type a command below.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Per trial: 30 seconds · 6 action batches. Per session: 30 API requests maximum.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Saves timings, actions, screenshots, and accessibility data locally:")
                        Text(model.benchmarkExportDirectory?.path ?? "~/Library/Application Support/Mouse/Benchmarks")
                            .textSelection(.enabled)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    if let status = model.benchmarkStatus {
                        Text(status)
                            .font(.caption).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if model.benchmarkEnabled || model.benchmarkTrialInProgress {
                        HStack {
                            Text("\(model.benchmarkRequestCount) / 30 session requests")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            if model.benchmarkTrialInProgress {
                                Button("Stop trial") { model.stopBenchmarkTrial() }
                                    .controlSize(.small)
                            }
                        }
                    }

                    HStack {
                        Button("Open export folder") {
                            if let directory = model.benchmarkExportDirectory {
                                NSWorkspace.shared.open(directory)
                            }
                        }
                        .disabled(model.benchmarkExportDirectory == nil)

                        Button("Reveal latest result") {
                            if let result = model.benchmarkLatestResultURL {
                                NSWorkspace.shared.activateFileViewerSelecting([result])
                            }
                        }
                        .disabled(model.benchmarkLatestResultURL == nil)
                    }
                    .controlSize(.small)
                }
                .padding(.top, 12)
            }
        }
        .font(.callout)
    }
}
