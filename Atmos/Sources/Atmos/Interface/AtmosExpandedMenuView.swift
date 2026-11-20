import AppKit
import SwiftUI

enum AtmosMenuPage: Equatable {
    case home, settings
}

@MainActor
final class AtmosMenuNavigation: ObservableObject {
    @Published var page: AtmosMenuPage
    @Published var isFullScreen = false

    init(page: AtmosMenuPage = .home) { self.page = page }
}

@MainActor
struct AtmosExpandedMenuView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var navigation: AtmosMenuNavigation
    let perform: (@escaping () -> Void) -> Void
    let dismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let short = geometry.size.height < 240
            let barHeight: CGFloat = short ? 38 : 54
            AtmosMenuPageTransition(page: navigation.page, keepsControlsInteractive: true) { displayed in
                ZStack(alignment: .top) {
                    Group {
                        switch displayed {
                        case .home:
                            home(size: geometry.size, barHeight: barHeight)
                        case .settings:
                            AtmosMenuSettingsView(model: model, perform: perform)
                                .padding(.top, barHeight)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(displayed == navigation.page)
                    .accessibilityHidden(displayed != navigation.page)
                    HStack(spacing: short ? 7 : 10) {
                        toolbarButton(navigation.isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                      label: navigation.isFullScreen ? "Exit Full Screen" : "Enter Full Screen", short: short) {
                            navigation.isFullScreen.toggle()
                        }
                        toolbarButton(model.microphoneMuted ? "mic.slash.fill" : "mic.fill",
                                      label: model.microphoneMuted ? "Unmute microphone" : "Mute microphone",
                                      short: short, action: model.toggleMenuMicrophoneMute)
                        Spacer(minLength: 0)
                        toolbarButton(displayed == .home ? "gearshape" : "house",
                                      label: navigation.page == .home ? "Settings" : "Home", short: short) {
                            navigation.page = navigation.page == .home ? .settings : .home
                        }
                        toolbarButton("xmark", label: "Close menu (Esc)", short: short, action: dismiss)
                    }
                    .padding(.horizontal, max(14, min(40, geometry.size.width * 0.031)))
                    .padding(.top, short ? 3 : 9)
                }
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .onChange(of: navigation.page, initial: true) { _, page in
            model.setMenuVoicePageVisible(page == .home)
        }
        .onDisappear { model.setMenuVoicePageVisible(false) }
    }

    private func toolbarButton(_ symbol: String, label: String, short: Bool, action: @escaping () -> Void) -> some View {
        let size: CGFloat = short ? 29 : 36
        return Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: .circle)
                .atmosMenuElement(-1)
                // The button stays operable as its artwork fades in and out.
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func home(size: CGSize, barHeight: CGFloat) -> some View {
        let narrow = size.width < 600
        let short = size.height < 240
        let titleSize: CGFloat = short || size.width < 420 ? 30 : narrow ? 38 : 50
        let titleHeight = ceil(titleSize * 1.25)
        let gap: CGFloat = short ? 12 : 22
        let controlSize: CGFloat = short || narrow ? 32 : 38
        let padding: CGFloat = short ? 6 : 9
        let baseHeight = controlSize + padding * 2
        let top = max(barHeight, (size.height - titleHeight - gap - baseHeight) / 2)
        let error = model.menuVoiceError.flatMap { $0.isEmpty ? nil : $0 }
        let errorSpace: CGFloat = error == nil ? 0 : gap + (short ? 18 : 36)
        let maxEditorHeight = max(controlSize, size.height - top - titleHeight - gap - padding * 2 - 12 - errorSpace)
        let fontSize: CGFloat = short || narrow ? 17 : 20
        let editorInset = max(0, (controlSize - ceil(fontSize * 1.2)) / 2)

        return VStack(spacing: gap) {
            Text("Let's Plan Your Day")
                .font(.system(size: titleSize, weight: .medium, design: .rounded))
                .tracking(-0.7)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: titleHeight)
                .accessibilityAddTraits(.isHeader)
                .atmosMenuElement(0)

            HStack(alignment: .top, spacing: narrow ? 5 : 10) {
                Button(action: model.toggleMenuDictation) {
                    Image(systemName: model.isMenuDictating ? "waveform" : "mic")
                        .font(.system(size: fontSize - 2, weight: .medium))
                        .foregroundStyle(model.isMenuDictating ? Color.mint : .white.opacity(0.88))
                        .frame(width: controlSize, height: controlSize)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(model.microphoneMuted)
                .help(model.menuVoiceError ?? (model.isMenuDictating ? "Finish dictation" : "Dictate a command"))
                .accessibilityLabel(model.isMenuDictating ? "Finish dictation" : "Dictate a command")
                .accessibilityHint(model.menuVoiceError ?? "")

                ZStack {
                    MenuCommandEditor(text: Binding(get: { model.menuCommandDraft },
                                                    set: { model.editMenuCommandDraft($0) }),
                                      fontSize: fontSize, maximumHeight: maxEditorHeight - 2 * editorInset,
                                      active: navigation.page == .home, submit: send)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, editorInset)
                    if model.menuCommandDraft.isEmpty {
                        Text("What should I do for you?")
                            .font(.system(size: fontSize))
                            .foregroundStyle(.white.opacity(0.61))
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                            .multilineTextAlignment(.center)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: controlSize)
                Button(action: send) {
                    Image(systemName: "arrow.up")
                        .font(.system(size: fontSize - 3, weight: .semibold))
                        .frame(width: controlSize, height: controlSize)
                        .background(.white.opacity(0.16), in: Circle())
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .disabled(model.menuCommandDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel("Send command")
                .help("Send command (Return)")
            }
            .padding(padding)
            .background(.white.opacity(0.085), in: RoundedRectangle(cornerRadius: baseHeight / 2))
            .overlay(RoundedRectangle(cornerRadius: baseHeight / 2)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .frame(maxWidth: 680)
            .atmosMenuElement(1)
            if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.white.opacity(0.85))
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(short ? 1 : 2)
                    .help(error)
                    .frame(maxWidth: 660)
                    .atmosMenuElement(2)
            }
        }
        .padding(.horizontal, narrow ? 16 : 36)
        .frame(maxWidth: .infinity)
        .padding(.top, top)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func send() {
        guard navigation.page == .home, let command = model.takeMenuCommandDraft() else { return }
        perform { model.submit(command) }
    }
}

// A nested Settings tab change and a change of the enclosing page share the
// same stages. The outer transition still reaches elements inside a nested deck.
private enum MenuTransitionPhase { case visible, leaving, concealed }
private struct MenuTransitionKey: EnvironmentKey {
    static let defaultValue = MenuTransitionPhase.visible
}

private extension EnvironmentValues {
    var menuTransition: MenuTransitionPhase {
        get { self[MenuTransitionKey.self] }
        set { self[MenuTransitionKey.self] = newValue }
    }
}

@MainActor
struct AtmosMenuPageTransition<Page: Equatable, Content: View>: View {
    let page: Page
    let keepsControlsInteractive: Bool
    @ViewBuilder var content: (Page) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.menuTransition) private var enclosingPhase
    @State private var displayed: Page
    @State private var phase = MenuTransitionPhase.visible

    init(page: Page, keepsControlsInteractive: Bool = false, @ViewBuilder content: @escaping (Page) -> Content) {
        self.page = page
        self.content = content
        self.keepsControlsInteractive = keepsControlsInteractive
        _displayed = State(initialValue: page)
    }

    var body: some View {
        content(displayed)
            .environment(\.menuTransition, enclosingPhase == .visible ? phase : enclosingPhase)
            .allowsHitTesting(keepsControlsInteractive || (page == displayed && phase == .visible))
            .accessibilityHidden(!keepsControlsInteractive && (page != displayed || phase != .visible))
            .task(id: page) {
                guard displayed != page else { phase = .visible; return }
                guard !reduceMotion else { displayed = page; phase = .visible; return }
                phase = .leaving
                do {
                    try await Task.sleep(for: .milliseconds(280))
                    // Mount new elements concealed before their entrance begins.
                    phase = .concealed
                    displayed = page
                    try await Task.sleep(for: .milliseconds(24))
                    phase = .visible
                } catch { /* A newer page request owns the transition. */ }
            }
    }
}

extension View {
    func atmosMenuElement(_ order: Int) -> some View { modifier(MenuElementTransition(order: order)) }
}

private struct MenuElementTransition: ViewModifier {
    let order: Int
    @Environment(\.menuTransition) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = phase == .visible || reduceMotion
        let index = min(4, max(-1, order))
        let delay = Double(visible ? 4 - index : index + 1) * 0.022
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible ? 0 : 12)
            .blur(radius: visible ? 0 : 4)
            .animation(reduceMotion || phase == .concealed ? nil : .easeInOut(duration: 0.16).delay(delay),
                       value: phase)
    }
}

/// A native multiline editor keeps selection, IME composition, keyboard
/// navigation and scrolling available when dictation fills the visible space.
private struct MenuCommandEditor: NSViewRepresentable {
    @Environment(\.menuTransition) private var phase
    @Binding var text: String
    let fontSize: CGFloat
    let maximumHeight: CGFloat
    let active: Bool
    let submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = CommandTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        let editor = scroll.documentView as! NSTextView
        editor.delegate = context.coordinator
        editor.drawsBackground = false
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.textContainerInset = .zero
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.insertionPointColor = .white
        editor.textColor = .white
        editor.setAccessibilityLabel("Command")
        editor.setAccessibilityHelp("What should I do for you? Press Return to send or Shift-Return for a new line.")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? NSTextView else { return }
        let coordinator = context.coordinator
        coordinator.owner = self
        if editor.font?.pointSize != fontSize { editor.font = .systemFont(ofSize: fontSize) }
        editor.alignment = .center
        if editor.string != text, !editor.hasMarkedText() {
            let oldLength = (editor.string as NSString).length
            let selection = editor.selectedRange()
            editor.string = text
            let length = (text as NSString).length
            let start = selection.location == oldLength ? length : min(selection.location, length)
            let updated = NSRange(location: start, length: min(selection.length, length - start))
            editor.setSelectedRange(updated)
            if updated.location == length { editor.scrollRangeToVisible(updated) }
        }
        let editable = active && phase == .visible
        editor.isEditable = editable
        if editable && !coordinator.wasActive {
            (editor as? CommandTextView)?.requestFocus()
        } else if !editable, editor.window?.firstResponder === editor {
            editor.window?.makeFirstResponder(nil)
        }
        coordinator.wasActive = editable
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        let height = context.coordinator.measure(text, width: width, fontSize: fontSize)
        return CGSize(width: width, height: min(ceil(height), maximumHeight))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var owner: MenuCommandEditor
        var wasActive = false
        private let storage = NSTextStorage()
        private let layout = NSLayoutManager()
        private let container = NSTextContainer()

        init(_ owner: MenuCommandEditor) {
            self.owner = owner
            super.init()
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
        }

        func measure(_ text: String, width: CGFloat, fontSize: CGFloat) -> CGFloat {
            let font = NSFont.systemFont(ofSize: fontSize)
            if storage.string != text || (storage.length > 0 && (storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont) != font) {
                storage.setAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
            }
            container.size = CGSize(width: width, height: .greatestFiniteMagnitude)
            layout.ensureLayout(for: container)
            return max(layout.defaultLineHeight(for: font), layout.usedRect(for: container).maxY,
                       layout.extraLineFragmentRect.maxY)
        }

        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView, owner.active else { return }
            owner.text = editor.string
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  !textView.hasMarkedText() else { return false }
            owner.submit()
            return true
        }
    }
}

private final class CommandTextView: NSTextView {
    private var needsInitialFocus = false

    func requestFocus() {
        needsInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.needsInitialFocus, self.isEditable, let window = self.window,
                  window.attachedSheet == nil else { return }
            self.needsInitialFocus = !window.makeFirstResponder(self)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, needsInitialFocus { requestFocus() }
    }

    override func keyDown(with event: NSEvent) {
        if (event.keyCode == 36 || event.keyCode == 76), event.modifierFlags.contains(.shift), !hasMarkedText() {
            insertText("\n", replacementRange: selectedRange())
        } else {
            super.keyDown(with: event)
        }
    }
}
