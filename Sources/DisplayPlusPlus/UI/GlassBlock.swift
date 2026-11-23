import AppKit
import SwiftUI

/// Liquid Glass backdrop, applied *behind* SwiftUI content rather than wrapping it.
///
/// The blocks are `NSGlassEffectView`s on macOS 26+, so the tint, specular edge and
/// interactive response come from Apple rather than from a hand-tuned blur.
///
/// Sizing note: an earlier version hosted the SwiftUI content *inside* the glass
/// view's `contentView`. That deadlocks layout — the glass sizes to its content,
/// the content sizes to the glass, and the block collapses to zero. Putting the
/// glass in `.background()` breaks the cycle: content decides the frame, glass
/// fills it.
struct GlassBackground: NSViewRepresentable {
    var cornerRadius: CGFloat
    var tint: Color?
    var interactive: Bool

    func makeNSView(context: Context) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.style = .regular
        apply(view)
        return view
    }

    func updateNSView(_ view: NSGlassEffectView, context: Context) {
        apply(view)
    }

    private func apply(_ view: NSGlassEffectView) {
        view.cornerRadius = cornerRadius
        view.tintColor = tint.map { NSColor($0) }
        if #available(macOS 27.0, *) {
            view.effectIsInteractive = interactive
        }
    }
}

extension View {
    /// A rounded glass container for a panel section.
    func glassBlock(cornerRadius: CGFloat = PanelMetrics.blockCornerRadius,
                    tint: Color? = nil,
                    interactive: Bool = true) -> some View {
        modifier(GlassBlockModifier(cornerRadius: cornerRadius, tint: tint, interactive: interactive))
    }
}

/// Chooses between the real glass view and an equivalent static treatment when
/// rendering offscreen. Keeping both branches in one modifier means the preview
/// cannot drift from the shipping UI.
private struct GlassBlockModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let interactive: Bool

    func body(content: Content) -> some View {
        if RenderMode.isOffscreen {
            content
                .background(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(Color.white.opacity(0.30))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.45), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
                )
        } else {
            content.background(
                GlassBackground(cornerRadius: cornerRadius, tint: tint, interactive: interactive)
            )
        }
    }
}

/// A flat row background for the inner menu rows: an inset rounded highlight on
/// hover.
struct RowHighlight: ViewModifier {
    @StateObject private var hover = StateBox(false)

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hover.value ? 0.07 : 0))
            )
            .onHover { hover.value = $0 }
    }
}

extension View {
    func rowHighlight() -> some View { modifier(RowHighlight()) }
}
