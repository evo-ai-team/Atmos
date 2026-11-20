import AppKit
import SwiftUI

/// Full text stays in the Answers tab even after its brief notch notice disappears.
struct QuestionAnswersView: View {
    @ObservedObject var model: AppModel
    let submit: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                TextField("Ask a question", text: $model.command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Button("Ask", action: submit)
                    .buttonStyle(.glass)
                    .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 28)
            .atmosMenuElement(1)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Answers").font(.headline)
                        Spacer()
                        Text("This session · newest first")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .atmosMenuElement(2)

                    if model.answers.isEmpty {
                        ContentUnavailableView(
                            "No answers yet",
                            systemImage: "text.bubble",
                            description: Text("Ask a question to see the full response here.")
                        )
                        .frame(maxWidth: .infinity)
                        .atmosMenuElement(3)
                    } else {
                        ForEach(model.answers.reversed().enumerated(), id: \.element.id) { index, answer in
                            QuestionAnswerRow(answer: answer)
                                .atmosMenuElement(min(4, index + 3))
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
            }
            .scrollIndicators(.automatic)
        }
    }
}

private struct QuestionAnswerRow: View {
    let answer: QuestionAnswer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(answer.createdAt.formatted(date: .numeric, time: .standard))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer.text, forType: .string)
                } label: {
                    Label("Copy answer", systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Copy full answer")
            }
            Text(answer.question)
                .font(.callout.weight(.semibold))
                .textSelection(.enabled)
            // Keep arbitrary response text literal and let every paragraph wrap
            // within the window; the complete answer never inherits notch limits.
            Text(verbatim: answer.text)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 18))
    }
}
