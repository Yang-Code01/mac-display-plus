import SwiftUI

/// One display block of the app menu.
///
/// Layout: header (name + switch), the prominent
/// "Configure Device Control…" button, brightness, volume, resolution, then the
/// fourteen submenu rows, then the two switches, then the collapse chevron.
///
/// Rows that have no working backend on this machine still appear, because their
/// absence is more confusing than a row that explains itself when opened. They are
/// never *silently* dead: opening one says what is missing.
struct DisplayBlockView: View {
    @ObservedObject var model: PanelModel
    let device: DisplayDevice
    var isCollapsed: Bool
    var onToggleCollapse: () -> Void
    var onOpen: (AppMenuSubmenu) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if !isCollapsed {
                VStack(alignment: .leading, spacing: 4) {
                    PanelProminentButton(title: L("Configure Device Control…"), symbol: "slider.horizontal.2.square") {
                        onOpen(.deviceControl)
                    }
                    .padding(.top, 6)

                    brightnessRow
                    volumeRow
                    resolutionRow
                }
                .padding(.horizontal, 6)

                VStack(alignment: .leading, spacing: 0) {
                    ForEach(AppMenuSubmenu.allCases.filter { Preferences.menuRowEnabled($0) }, id: \.self) { submenu in
                        PanelRow(
                            symbol: submenu.symbol,
                            title: submenu.title,
                            kind: .submenu,
                            value: rowValue(submenu)
                        ) {
                            onOpen(submenu)
                        }
                    }

                    PanelRow(
                        symbol: model.canToggleHiDPI(device) ? "sparkles" : "sparkles",
                        title: L("High Resolution (HiDPI)"),
                        kind: .action,
                        value: model.hiDPIHint(device),
                        isEnabled: model.canToggleHiDPI(device)
                    ) {
                        model.toggleHiDPI(device)
                    }

                    PanelRow(
                        symbol: "m.circle",
                        title: L("Set as Main Display"),
                        kind: .action,
                        isEnabled: !model.isMain(device),
                        isSelected: false
                    ) {
                        model.setMainDisplay(device)
                    }
                }
                .padding(.top, 6)

                if let notice = model.notice(device) {
                    Text(notice)
                        .font(PanelMetrics.captionFont)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                }
            }

            PanelCollapseChevron(isCollapsed: isCollapsed, action: onToggleCollapse)
                .padding(.top, 2)
        }
        .padding(.horizontal, PanelMetrics.innerPadding)
        .padding(.vertical, 8)
        .glassBlock()
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: device.isBuiltIn ? "laptopcomputer" : "display")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: PanelMetrics.headerIconSize)

            Text(device.name)
                .font(PanelMetrics.titleFont)
                .lineLimit(1)

            if model.isMain(device) {
                Text("M")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(Color.primary.opacity(0.10)))
            }

            Spacer(minLength: 4)

            MiniSwitch(isOn: headerSwitchBinding, help: headerSwitchHelp)
                .frame(width: 36, height: 20)
                .scaleEffect(1.33)
        }
        .frame(height: PanelMetrics.headerHeight)
        .padding(.horizontal, 6)
    }

    private var headerSwitchHelp: String {
        usesConnectSwitch ? L("Connect or disconnect this display") : L("Brightness keys control this display")
    }

    /// Whether the header switch is the display's connect switch at all. It is only that
    /// when the user left connection options enabled *and* the display can be disconnected;
    /// otherwise the switch is the keyboard target, which is the one per-display switch that
    /// always has a visible effect.
    private var usesConnectSwitch: Bool {
        Preferences.connectOptions && model.canDisconnect(device)
    }

    /// The header switch is the display's connect switch. This machine has that
    /// backend (a private but verified window-server call), so it is used here; on a
    /// display that cannot be disconnected the switch falls back to the brightness-key
    /// target, which is the one per-display switch that always has a real effect.
    private var headerSwitchBinding: Binding<Bool> {
        if usesConnectSwitch {
            return Binding(
                get: { model.isEnabled(device) },
                set: { model.setEnabled(device, $0) }
            )
        }
        return Binding(
            get: { model.isKeyboardTarget(device) },
            set: { model.setKeyboardTarget(device, $0) }
        )
    }

    // MARK: - Sliders

    private var brightnessRow: some View {
        PanelSliderRow(
            caption: model.brightnessCaption(for: device),
            valueText: model.brightnessLabel(device),
            symbol: "sun.max.fill",
            value: Binding(
                get: { model.brightness(device) },
                set: { model.setBrightness($0, device) }
            )
        )
    }

    private var volumeRow: some View {
        PanelSliderRow(
            caption: model.volumeCaption(for: device),
            valueText: model.isMuted(device) ? L("Muted") : model.volumeLabel(device),
            symbol: model.isMuted(device) ? "speaker.slash.fill" : "speaker.wave.2.fill",
            value: Binding(
                get: { model.volume(device) },
                set: { model.setVolume($0, device) }
            ),
            isEnabled: model.canControlVolume(device),
            trailing: AnyView(
                Button {
                    model.toggleMute(device)
                } label: {
                    Image(systemName: model.isMuted(device) ? "speaker.slash.fill" : "speaker.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(!model.canControlVolume(device))
            )
        )
    }

    private var resolutionRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            PanelSliderRow(
                caption: L("Resolution"),
                valueText: model.resolutionLabel(device),
                symbol: "square.resize",
                value: Binding(
                    get: { model.resolutionSliderValue(device) },
                    set: { model.previewResolutionSlider($0, device) }
                ),
                onEditingChanged: { editing in
                    if !editing { model.commitResolutionSlider(device) }
                }
            )

            if model.isSwitchingResolution(device) {
                Text(L("Switching — the screen blanks while the display resyncs."))
                    .font(PanelMetrics.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
    }

    /// Right-hand value for a submenu row, when the row has one worth showing.
    private func rowValue(_ submenu: AppMenuSubmenu) -> String? {
        switch submenu {
        case .refreshRate:
            return device.currentMode.map { String(format: "%.0f Hz", $0.refreshRate) }
        case .rotation:
            return model.rotationLabel(device)
        case .inputSource:
            return model.inputSource(device)?.label
        default:
            return nil
        }
    }
}
