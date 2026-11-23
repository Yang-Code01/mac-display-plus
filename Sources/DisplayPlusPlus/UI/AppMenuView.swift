import SwiftUI

/// The panel's root: one block per display, then the tools block, then the footer.
///
/// Order: display blocks, Tools block (Displays and Virtual Screens / System Colors /
/// Check for Updates / Quit), then a footer row with the version line on the left and
/// the gear + ellipsis on the right.
struct AppMenuView: View {
    @ObservedObject var model: PanelModel
    var onClose: () -> Void
    var onSettings: () -> Void
    var onQuit: () -> Void

    var width: CGFloat = PanelMetrics.panelWidth
    /// Set when the panel has to fit a short screen; the display blocks then scroll
    /// and the tools/footer stay pinned.
    var heightBudget: CGFloat? = nil

    @StateObject private var route = StateBox<AppMenuRoute>(.root)
    @StateObject private var collapsed = StateBox<Set<UInt32>>([])
    @StateObject private var toolsExpanded = StateBox(true)

    var body: some View {
        VStack(spacing: PanelMetrics.blockSpacing) {
            switch route.value {
            case .root:
                rootContent
            case .submenu(let wrapper, let submenu):
                let device = model.devices.first { $0.id == wrapper.raw } ?? model.devices[0]
                SubmenuView(model: model, device: device, submenu: submenu) {
                    route.value = .root
                }
            }
        }
        .padding(PanelMetrics.outerPadding)
        .frame(width: width)
        .onAppear { model.refreshVolume() }
    }

    // MARK: - Root

    private var rootContent: some View {
        VStack(spacing: PanelMetrics.blockSpacing) {
            if heightBudget != nil {
                ScrollView(.vertical, showsIndicators: false) {
                    displayBlocks
                }
                .frame(maxHeight: .infinity)
            } else {
                displayBlocks
            }

            if toolsExpanded.value {
                toolsBlock
            }

            footer
        }
    }

    private var displayBlocks: some View {
        VStack(spacing: PanelMetrics.blockSpacing) {
            ForEach(model.devices) { device in
                DisplayBlockView(
                    model: model,
                    device: device,
                    isCollapsed: collapsed.value.contains(device.id),
                    onToggleCollapse: {
                        if collapsed.value.contains(device.id) {
                            collapsed.value.remove(device.id)
                        } else {
                            collapsed.value.insert(device.id)
                        }
                    },
                    onOpen: { submenu in
                        route.value = .submenu(.init(device.id), submenu)
                    }
                )
            }
        }
    }

    /// The tools block. Two of its rows need a backend this build does not have
    /// (virtual screens, system colours), so they open a note instead of pretending.
    private var toolsBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Tools"))
                    .font(PanelMetrics.titleFont)
                Spacer()
            }
            .frame(height: PanelMetrics.headerHeight)
            .padding(.horizontal, 6)

            PanelRow(symbol: "display.2", title: L("Displays and Virtual Screens"), kind: .submenu) {
                SystemSettings.openDisplays()
            }
            PanelRow(symbol: "paintpalette", title: L("System Colors"), kind: .action) {
                SystemSettings.openDisplaysColorProfile()
            }
            PanelRow(symbol: "arrow.triangle.2.circlepath", title: L("Re-detect Displays"), kind: .action) {
                model.redetect()
            }
            PanelRow(symbol: "power", title: L("Quit display++"), kind: .action) {
                onQuit()
            }

            PanelCollapseChevron(isCollapsed: false) {
                withAnimation(.easeInOut(duration: 0.16)) { toolsExpanded.value.toggle() }
            }
        }
        .padding(.horizontal, PanelMetrics.innerPadding)
        .padding(.vertical, 8)
        .glassBlock()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(L("display++ 1.0"))
                .font(PanelMetrics.captionFont)
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Settings"))

            Button {
                withAnimation(.easeInOut(duration: 0.16)) { toolsExpanded.value.toggle() }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Show or hide Tools"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .frame(height: 26)
        .glassBlock(cornerRadius: 13)
    }
}

/// The handful of System Settings jumps the panel offers.
///
/// Deep links are the one stable way to hand off a control macOS will not let a
/// third-party app drive (arrangement, colour profile UI). URL strings are checked
/// rather than composed blindly: an unknown pane opens Settings to its last page,
/// which looks like a bug.
enum SystemSettings {
    private static func open(_ url: String) {
        guard let url = URL(string: url) else { return }
        NSWorkspace.shared.open(url)
    }

    static func openDisplays() { open("x-apple.systempreferences:com.apple.Displays-Settings.extension") }
    static func openDisplayArrangement() { open("x-apple.systempreferences:com.apple.Displays-Settings.extension?arrangement") }
    static func openDisplaysColorProfile() { open("x-apple.systempreferences:com.apple.Displays-Settings.extension?colorprofile") }
}
