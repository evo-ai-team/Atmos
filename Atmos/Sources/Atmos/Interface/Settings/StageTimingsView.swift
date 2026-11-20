import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// Refresh only while expanded: timing collection continues independently, and
/// hidden diagnostics should not introduce recurring work into the input path.
struct StageTimingsView: View {
    let traces: [PipelineTiming]
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup("Full timing logs", isExpanded: $isExpanded) {
            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent commands, newest first")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Copy timings") {
                            let report = traces.map(\.report).joined(separator: "\n\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(report, forType: .string)
                        }.disabled(traces.isEmpty)
                    }
                    if traces.isEmpty {
                        Text("Run a command to see its stage timings.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 16) {
                                    ForEach(traces, id: \.id) { trace in
                                        Text(trace.report)
                                            .font(.system(.caption, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }.frame(height: 320)
                        }
                    }
                }.padding(.top, 8)
            }
        }
    }
}
