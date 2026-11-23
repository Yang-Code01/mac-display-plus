import AppKit
import SwiftUI

/// Brightness/volume feedback in the same Liquid Glass material as the panel.
///
/// Segmented rather than a smooth bar: at a glance the user reads the number of
/// lit cells, which survives being glanced at for 200 ms far better than a
/// continuous fill does.
final class GlassOSDWindow: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 64),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar + 1
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A single OSD presentation: title, symbol, and a 0...1 level.
struct GlassOSDView: View {
    let symbol: String
    let title: String
    let level: Double
    let segments: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 2) {
                    ForEach(0..<segments, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(fillColor(for: index))
                            .frame(height: 9)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(width: 220)
    }

    private func fillColor(for index: Int) -> Color {
        let threshold = (Double(index) + 0.5) / Double(segments)
        return level >= threshold ? Color.primary.opacity(0.9) : Color.primary.opacity(0.16)
    }
}

/// Owns the single OSD window and its fade timing.
final class OSDController {
    static let shared = OSDController()

    private var window: GlassOSDWindow?
    private var hosting: NSHostingView<AnyView>?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func show(symbol: String, title: String, level: Double, on screen: NSScreen? = nil) {
        let target = screen ?? NSScreen.main ?? NSScreen.screens.first
        guard let target else { return }

        let view = GlassOSDView(symbol: symbol, title: title, level: level, segments: 16)
        let panel = window ?? GlassOSDWindow()

        if let existing = hosting {
            existing.rootView = AnyView(view)
        } else {
            let host = NSHostingView(rootView: AnyView(view))
            host.translatesAutoresizingMaskIntoConstraints = false
            let container = NSView()
            container.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                host.topAnchor.constraint(equalTo: container.topAnchor),
                host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            panel.contentView = container
            hosting = host
        }

        panel.contentView?.layoutSubtreeIfNeeded()
        let size = panel.contentView?.fittingSize ?? NSSize(width: 220, height: 64)
        panel.setContentSize(size)

        let frame = target.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.minY + 96
        ))

        window = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
    }

    func hide() {
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            self?.window?.orderOut(nil)
        }
    }
}
