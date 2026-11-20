import SwiftUI

/// A local execution trace. Selection, offered controls, and dispatched input are
/// shown separately because a model decision is not proof that an action ran.
struct ActivityDiagnosticsView: View {
    @ObservedObject var model: AppModel
    let submit: () -> Void
    @State private var showDiagnostics = false
    @State private var targetQuery = ""

    var body: some View {
        DisclosureGroup("Testing & recent activity", isExpanded: $showDiagnostics) {
            if showDiagnostics {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        TextField("Type a command", text: $model.command).textFieldStyle(.roundedBorder).onSubmit(submit)
                        Button("Run", action: submit).disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let goal = model.lastAcceptedGoal {
                            Text("Last accepted goal").font(.caption.weight(.medium))
                            Text(goal).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Text("Latest selection").font(.caption.weight(.medium))
                        Text(model.latestDecision).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        Text("Actual input").font(.caption.weight(.medium))
                        Text(model.latestDispatch).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    DisclosureGroup("Controls offered for last action") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(model.lastActionTreeSummary).font(.caption).textSelection(.enabled)
                            TextField("Find a control", text: $targetQuery).textFieldStyle(.roundedBorder)
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.lastActionTargets.filter {
                                        targetQuery.isEmpty || $0.description.localizedCaseInsensitiveContains(targetQuery)
                                    }, id: \.value) { choice in
                                        Text(choice.description).font(.caption).textSelection(.enabled)
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 180)
                            Text("A control missing from this list could not be selected through accessibility.")
                                .font(.caption).foregroundStyle(.secondary)
                        }.padding(.top, 8)
                    }
                    ForEach(model.activity) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.callout).textSelection(.enabled)
                            Text(item.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.padding(.top, 12)
            }
        }.font(.callout)
    }
}
