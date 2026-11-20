import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// The coordinator retains the latest accepted command separately from the
/// bounded full logs, so ignored or interrupted speech cannot evict this summary.
struct LatestActionTimingView: View {
    let trace: PipelineTiming?
    @State private var showStages = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            if let trace {
                let snapshot = trace.snapshot
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Latest command").font(.subheadline.weight(.medium))
                        Spacer()
                        Text(snapshot.outcome.rawValue.capitalized)
                            .font(.caption).foregroundStyle(.secondary)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(trace.report, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy latest timing log")
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 20) {
                        metric(snapshot.outcome == .running ? "Elapsed" : "Total time", duration: snapshot.totalDuration)
                        if let firstInput = snapshot.firstInputDuration {
                            metric("First input", duration: firstInput)
                        }
                    }
                    DisclosureGroup("Time per stage", isExpanded: $showStages) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 7) {
                                ForEach(snapshot.stages) { stage in
                                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(stage.name).font(.caption)
                                            if stage.outcome != .succeeded {
                                                Text(stage.outcome.rawValue).font(.caption2).foregroundStyle(.secondary)
                                            }
                                        }
                                        Spacer(minLength: 4)
                                        Text(milliseconds(stage.duration)).font(.caption.monospacedDigit())
                                    }
                                }
                            }.padding(.trailing, 6)
                        }.frame(maxHeight: 240).padding(.top, 8)
                        Text("Stages can overlap. First input measures dispatch, not verified success.")
                            .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
                    }
                }
            } else {
                Text("Run a command to see total time and stage logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func metric(_ title: String, duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(milliseconds(duration)).font(.title3.monospacedDigit())
        }
    }

    private func milliseconds(_ duration: TimeInterval) -> String {
        String(format: "%.0f ms", duration * 1_000)
    }
}
