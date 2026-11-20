import AppKit
import SwiftUI
#if SWIFT_PACKAGE
import AtmosCore
#endif

/// The session's dispatch ledger, separate from the model's description of its
/// intent. Entries survive the end of a command and update as dispatch finishes.
struct ActionHistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Actions").font(.headline)
                        Spacer()
                        Text(model.actionHistory.entries.count.formatted())
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Text("This session · newest first")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Dispatched means the action finished dispatching, not that the goal was verified. Wait and screenshot actions send no input.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .atmosMenuElement(1)

                if model.actionHistory.entries.isEmpty {
                    ContentUnavailableView(
                        "No actions yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Run a command to see the model's descriptions and the actual actions here.")
                    )
                    .frame(maxWidth: .infinity)
                    .atmosMenuElement(2)
                } else {
                    ForEach(model.actionHistory.entries.reversed().enumerated(), id: \.element.id) { index, entry in
                        ActionHistoryRow(entry: entry)
                            .atmosMenuElement(min(4, index + 2))
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.automatic)
    }
}

private struct ActionHistoryRow: View {
    let entry: ActionHistory.Entry
    @State private var showsPayload = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.source).font(.callout.weight(.semibold))
                Spacer()
                Text(entry.status.rawValue)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
            }
            Text(entry.recordedAt.formatted(date: .numeric, time: .standard))
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            labeledText("Goal", entry.goal)
            labeledText("Model description", entry.description)

            // Expanded initially so the user can compare the model's wording
            // with the exact payload, including no-input waits and screenshots.
            DisclosureGroup(isExpanded: $showsPayload) {
                ScrollView(.horizontal) {
                    Text(entry.payloadJSON)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 4)
            } label: {
                HStack {
                    Text("Actual action").font(.caption.weight(.medium))
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.payloadJSON, forType: .string)
                    } label: {
                        Label("Copy action JSON", systemImage: "doc.on.doc")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy exact action JSON")
                }
            }

            if let detail = entry.detail, !detail.isEmpty {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }

    private var statusColor: Color {
        switch entry.status {
        case .uncertain: return .orange
        case .dispatching: return .accentColor
        case .dispatched: return .secondary
        }
    }

    private func labeledText(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.callout).textSelection(.enabled)
        }
    }
}
