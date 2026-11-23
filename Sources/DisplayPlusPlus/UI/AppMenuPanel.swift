import AppKit
import SwiftUI

/// The attached, non-activating panel that drops from the menu bar.
///
/// A regular `NSPopover` cannot host the Liquid Glass blocks correctly (it
/// clips to its own arrow-less shape and swallows the interactive glass), and
/// it would steal focus from the app the user is working in. A borderless
/// `NSPanel` that becomes key only when it needs to, positioned under the status
/// item, avoids both problems.
final class AppMenuPanel: NSPanel {
    init(width: CGFloat, content: some View) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        hidesOnDeactivate = false
        isMovable = false
        animationBehavior = .none

        let hosting = NSHostingView(rootView: AnyView(content))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        // The panel itself is transparent; the glass blocks supply the backdrop.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        contentView = container

        // Nothing may draw outside the window rect. Without this a transient
        // layout pass during a resolution change can leave a row's background
        // visible past the panel edge.
        container.wantsLayer = true
        container.layer?.masksToBounds = true

        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Positions the panel under the status item, keeps it inside the screen, and
/// rebuilds it when the screen itself changes size.
///
/// The resolution slider lives inside this panel, so the panel is routinely open
/// while the display is being reconfigured. The screen can therefore shrink
/// underneath a panel whose height was measured for the old screen — the panel
/// then extends past the menu bar / past the bottom edge, which is exactly the
/// artifact this class exists to prevent. Everything is therefore recomputed from
/// the *current* anchor screen rather than cached from when the panel opened.
final class AppMenuPanelController {
    /// Gap kept between the panel and the screen edge.
    private static let edgeInset: CGFloat = 6

    private var panel: AppMenuPanel?
    private var monitor: Any?
    private let model: PanelModel

    /// The status item button the panel is currently hanging from. Weak: the
    /// menu bar owns it.
    private weak var anchorButton: NSStatusBarButton?
    /// Height the visible panel was sized to, used to detect "the new screen
    /// cannot hold this any more".
    private var visibleBudget: CGFloat?
    /// Anchor screen geometry the current frame was computed for. Reconfiguring a
    /// *different* display must not make this panel jump around.
    private var layoutScreenFrame: NSRect?
    private var relayoutWork: DispatchWorkItem?

    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(model: PanelModel) {
        self.model = model

        // The canonical AppKit signal for "the screen arrangement changed".
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleRelayout),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
        // Fires earlier than the above, straight off our own mode change, so the
        // panel is already correct by the time the screen parameters settle.
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleRelayout),
            name: .displayModeChanged, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(relativeTo button: NSStatusBarButton?) {
        if isVisible { close() } else { show(relativeTo: button) }
    }

    // MARK: - Open / close

    func show(relativeTo button: NSStatusBarButton?) {
        close()
        anchorButton = button
        layoutScreenFrame = nil
        visibleBudget = nil

        let panel = makePanel(sizeToContent: true)
        panel.makeKeyAndOrderFront(nil)
        self.panel = panel
        applyLayout(to: panel, force: true)
        installOutsideClickMonitor()
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        relayoutWork?.cancel()
        relayoutWork = nil
        panel?.orderOut(nil)
        panel = nil
        visibleBudget = nil
        layoutScreenFrame = nil
    }

    private func installOutsideClickMonitor() {
        // Dismiss on any click outside. A local monitor would miss clicks in
        // other apps, so this is global; the callback only closes, never
        // consumes, so other apps still receive their click.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, let panel = self.panel else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                self.close()
            }
        }
    }

    // MARK: - Building

    /// Builds a panel, optionally collapsing to a content-sized frame.
    ///
    /// `sizeToContent` runs the expensive measure; the capped path just pins the
    /// window to `budget` and lets the ScrollView absorb the difference, because
    /// the hosting view is constrained to the content view and therefore receives
    /// the window's real height as its proposal.
    private func makePanel(sizeToContent: Bool) -> AppMenuPanel {
        let geometry = budget(for: anchorScreen)

        var panel = AppMenuPanel(width: geometry.width, content: makeView(width: geometry.width, budget: nil))
        var height = AppMenuPanelController.measuredHeight(of: panel)

        if height > geometry.height {
            panel = AppMenuPanel(width: geometry.width, content: makeView(width: geometry.width, budget: geometry.height))
            height = geometry.height
        }

        // Whatever the measurement said, the window may not be taller than the
        // space it has. This is the line that stops the panel poking out of a
        // freshly shrunk screen.
        height = min(max(height, 120), geometry.height)
        panel.setContentSize(NSSize(width: geometry.width, height: height))
        panel.contentView?.layoutSubtreeIfNeeded()
        visibleBudget = sizeToContent ? height : geometry.height
        return panel
    }

    private func makeView(width: CGFloat, budget: CGFloat?) -> AppMenuView {
        weak let weakSelf = self
        return AppMenuView(
            model: model,
            onClose: { weakSelf?.close() },
            onSettings: {
                weakSelf?.close()
                weakSelf?.onSettings?()
            },
            onQuit: {
                weakSelf?.close()
                weakSelf?.onQuit?()
            },
            width: width,
            heightBudget: budget
        )
    }

    // MARK: - Geometry

    /// Screen the panel belongs to: the one whose menu bar actually holds the
    /// status item.
    ///
    /// `NSStatusBarButton.window` is the shared menu-bar window, and with separate
    /// Spaces every display has one — `window.screen` picked the *external* display
    /// and the panel opened there, hundreds of points from the icon the user just
    /// clicked. Locating the button's own rect and hit-testing the screens is
    /// unambiguous.
    private var anchorScreen: NSScreen? {
        if let button = anchorButton, let window = button.window {
            let rect = window.convertToScreen(button.convert(button.bounds, to: nil))
            let point = NSPoint(x: rect.midX, y: rect.midY)
            if let hit = NSScreen.screens.first(where: { $0.frame.contains(point) }) {
                return hit
            }
            return window.screen ?? NSScreen.main
        }
        if let panelScreen = panel?.screen { return panelScreen }
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    private func budget(for screen: NSScreen?) -> (width: CGFloat, height: CGFloat) {
        Self.budget(forVisible: screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900))
    }

    /// Available panel size for a given visible frame.
    ///
    /// Pure so it can be tested against screen sizes this machine does not have.
    /// The absolute cap of 640 pt keeps the panel reading as a menu; the
    /// `visible.height - 2 * inset` term is what guarantees it can never exceed
    /// the screen it hangs on — that is the invariant behind "a resolution change
    /// must not push the panel out of the screen".
    nonisolated static func budget(forVisible visible: NSRect) -> (width: CGFloat, height: CGFloat) {
        let maxWidth = max(200, visible.width - edgeInset * 2)
        let width = min(PanelMetrics.panelWidth, maxWidth)

        // The panel fills the screen height when its content is taller than the
        // screen (measured: 873 pt on a 900 pt display, from the menu bar to just
        // above the Dock), and it scrolls rather than shrinking.
        // An earlier version capped this at 72% of the screen and 640 pt, which
        // made the panel look like a different, much shorter menu.
        let height = visible.height - edgeInset * 2
        return (width, max(160, height))
    }

    /// Places `panelSize` at `desired`, then pulls it fully inside `visible`.
    ///
    /// Both axes are clamped. An earlier version only clamped the left and bottom
    /// edges, so a panel taller than the screen grew out through the top.
    nonisolated static func clampedOrigin(panelSize: NSSize, desired: NSPoint, visible: NSRect) -> NSPoint {
        let maxX = visible.maxX - panelSize.width - edgeInset
        let maxY = visible.maxY - panelSize.height - edgeInset
        let x = min(max(desired.x, visible.minX + edgeInset), max(maxX, visible.minX + edgeInset))
        let y = min(max(desired.y, visible.minY + edgeInset), max(maxY, visible.minY + edgeInset))
        return NSPoint(x: x, y: y)
    }

    /// Places the panel under the status item and clamps it fully on screen.
    private func applyLayout(to panel: AppMenuPanel, force: Bool) {
        guard let screen = anchorScreen else { panel.center(); return }
        let visible = screen.visibleFrame

        // Skip when nothing that matters to this panel changed. Without this the
        // panel visibly jumps every time any display is reconfigured.
        if !force, let last = layoutScreenFrame, last.equalTo(visible) { return }

        if ProcessInfo.processInfo.environment["DPP_DEBUG"] != nil {
            var info = "place: screen=\(screen.localizedName) visible=\(visible)"
            if let b = anchorButton, let w = b.window {
                let r = w.convertToScreen(b.convert(b.bounds, to: nil))
                info += " button=\(r) windowFrame=\(w.frame) windowScreen=\(w.screen?.localizedName ?? "nil")"
            } else {
                info += " button=nil"
            }
            info += " panelSize=\(panel.frame.size)"
            FileHandle.standardError.write(Data((info + "\n").utf8))
        }

        var origin: NSPoint
        if let button = anchorButton, let window = button.window {
            let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
            // Hang from the bottom of this screen's menu bar rather than from the
            // button's own y, which comes from a window that may belong to a
            // different display than the one we just resolved.
            origin = NSPoint(
                x: buttonFrame.midX - panel.frame.width / 2,
                y: min(buttonFrame.minY, visible.maxY) - panel.frame.height - 4
            )
        } else {
            origin = NSPoint(
                x: visible.midX - panel.frame.width / 2,
                y: visible.maxY - panel.frame.height - 4
            )
        }

        origin = Self.clampedOrigin(panelSize: panel.frame.size, desired: origin, visible: visible)
        panel.setFrameOrigin(origin)
        layoutScreenFrame = visible
    }

    // MARK: - Reacting to a resolution change

    @objc private func scheduleRelayout() {
        relayoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.relayoutIfNeeded() }
        relayoutWork = work
        // Let the window server finish the reconfiguration before reading the new
        // screen geometry; reading immediately returns the old frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func relayoutIfNeeded() {
        guard let panel, panel.isVisible else { return }
        let geometry = budget(for: anchorScreen)

        // Rebuild only when the panel can no longer hold what it is showing.
        // Otherwise just move it — re-creating the window on every reconfiguration
        // would drop the user's expanded sections.
        let needsResize = panel.frame.height > geometry.height + 0.5
            || abs(panel.frame.width - geometry.width) > 0.5

        if needsResize {
            let replacement = makePanel(sizeToContent: false)
            replacement.alphaValue = 1
            replacement.makeKeyAndOrderFront(nil)
            applyLayout(to: replacement, force: true)
            panel.orderOut(nil)
            self.panel = replacement
            installOutsideClickMonitor()
        } else {
            applyLayout(to: panel, force: false)
        }
    }

    // MARK: - Measurement

    /// SwiftUI needs a run-loop turn before `fittingSize` reflects the real
    /// layout; reading it immediately returns a stale or zero height and the
    /// panel comes out the wrong size. Pump until it stops changing.
    static func measuredHeight(of panel: NSPanel) -> CGFloat {
        panel.contentView?.layoutSubtreeIfNeeded()
        var last: CGFloat = 0
        for _ in 0..<24 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.006))
            panel.contentView?.layoutSubtreeIfNeeded()
            let current = panel.contentView?.fittingSize.height ?? 0
            if abs(current - last) < 0.5, current > 0 { return current }
            last = current
        }
        return last
    }
}
