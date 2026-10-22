import AppKit
import SwiftUI

/// The content belongs to the glass view so AppKit can apply native vibrancy
/// and foreground contrast. The window backing must stay clear behind it.
struct NativeGlassSurface<Content: View>: NSViewRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeNSView(context: Context) -> GlassHostingView<Content> {
        GlassHostingView(content: content)
    }

    func updateNSView(_ view: GlassHostingView<Content>, context: Context) {
        withTransaction(context.transaction) { view.host.rootView = content }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: GlassHostingView<Content>, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 520,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 700)
    }
}

final class GlassHostingView<Content: View>: NSGlassEffectView {
    let host: NSHostingView<Content>

    init(content: Content) {
        host = NSHostingView(rootView: content)
        super.init(frame: .zero)
        style = .regular
        cornerRadius = 28
        host.sizingOptions = []
        // MouseView supplies its own traffic-light clearance. Avoid applying
        // the title-bar safe area a second time inside this nested host.
        host.safeAreaRegions = []
        contentView = host
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.isOpaque = false
        window.backgroundColor = .clear
        window.titlebarAppearsTransparent = true
        window.hasShadow = true
    }
}
