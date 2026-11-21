import AppKit
import SwiftUI

struct AtmosAnswerReader: View {
    let answer: QuestionAnswer
    @ObservedObject var navigation: AtmosMenuNavigation
    let onRead: (UUID) -> Void
    @Environment(\.menuTransition) private var phase

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(verbatim: answer.question)
                    .font(.system(size: navigation.isFullScreen ? 34 : 26, weight: .semibold, design: .rounded))
                    .accessibilityAddTraits(.isHeader)
                    .atmosMenuElement(0)
                Text(verbatim: answer.text)
                    .font(.system(size: 19))
                    .lineSpacing(5)
                    .foregroundStyle(.white.opacity(0.92))
                    .atmosMenuElement(1)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(answer.text, forType: .string)
                } label: {
                    Label("Copy answer", systemImage: "doc.on.doc")
                }
                .buttonStyle(.glass)
                .atmosMenuElement(2)
            }
            .textSelection(.enabled)
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 28)
            .padding(.top, navigation.isFullScreen ? 56 : 12)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: navigation.page == .answer(answer.id) && navigation.isAtFullHeight && phase == .visible,
                  initial: true) { _, isReading in
            if isReading { onRead(answer.id) }
        }
    }
}
