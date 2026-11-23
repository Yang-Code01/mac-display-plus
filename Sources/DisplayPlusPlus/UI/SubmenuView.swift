import SwiftUI

/// The content of a submenu, with a back row instead of a detached panel.
///
/// These could open in a second panel beside the menu. Pushing the content keeps one
/// window and the same glass, at the cost of the row you came from staying hidden —
/// noted in the README's difference table rather than pretended away.
struct SubmenuView: View {
    @ObservedObject var model: PanelModel
    let device: DisplayDevice
    let submenu: AppMenuSubmenu
    var onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            backRow

            Text(submenu.title)
                .font(PanelMetrics.titleFont)
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .padding(.bottom, 4)

            content
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, PanelMetrics.innerPadding)
        .padding(.vertical, 8)
        .glassBlock()
    }

    private var backRow: some View {
        Button(action: onBack) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                Text(device.name)
                    .font(PanelMetrics.captionFont)
                Spacer()
            }
            .foregroundStyle(.secondary)
            .frame(height: 18)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch submenu {
        case .displayMode:
            displayModeList
        case .refreshRate:
            refreshRateList
        case .mirror:
            mirrorList
        case .arrange:
            arrangeControls
        case .imageAdjustments:
            imageAdjustments
        case .deviceControl:
            deviceControl
        case .inputSource:
            inputSourceList
        case .manageDisplay:
            manageDisplay
        case .pip:
            streamControls(floating: true)
        case .colorProfile:
            colourProfile
        case .stream:
            streamControls(floating: false)
        default:
            unavailableNote(reason)
        }
    }

    private var displayModeList: some View {
        VStack(spacing: 0) {
            ForEach(device.resolutionChoices, id: \.rowKey) { mode in
                PanelRow(
                    symbol: "",
                    title: mode.fullLabel,
                    kind: .action,
                    value: mode.isHiDPI ? "HiDPI" : nil,
                    isSelected: isCurrent(mode)
                ) {
                    model.apply(mode, to: device)
                    onBack()
                }
            }
        }
    }

    private var refreshRateList: some View {
        VStack(spacing: 0) {
            ForEach(device.refreshChoices, id: \.self) { rate in
                PanelRow(
                    symbol: "",
                    title: String(format: "%.0f Hz", rate),
                    kind: .action,
                    isSelected: abs((device.currentMode?.refreshRate ?? 0) - rate) < 0.5
                ) {
                    model.setRefreshRate(rate, for: device)
                    onBack()
                }
            }
        }
    }

    private var mirrorList: some View {
        VStack(spacing: 0) {
            PanelRow(
                symbol: "rectangle.on.rectangle.slash",
                title: L("Don't Mirror"),
                kind: .action,
                isSelected: model.mirrorMaster(of: device) == nil
            ) {
                model.setMirror(device, of: nil)
                onBack()
            }
            ForEach(model.devices.filter { $0.id != device.id }) { other in
                PanelRow(
                    symbol: other.isBuiltIn ? "laptopcomputer" : "display",
                    title: L("Mirror of %@", other.name),
                    kind: .action,
                    isSelected: model.mirrorMaster(of: device)?.id == other.id
                ) {
                    model.setMirror(device, of: other)
                    onBack()
                }
            }
        }
    }

    private var arrangeControls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                moveButton("arrow.left", dx: -20, dy: 0)
                moveButton("arrow.up", dx: 0, dy: -20)
                moveButton("arrow.down", dx: 0, dy: 20)
                moveButton("arrow.right", dx: 20, dy: 0)
            }
            .padding(.top, 2)

            Text(L("Moves this display 20 pt. The window server keeps the layout from overlapping."))
                .font(PanelMetrics.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)

            PanelRow(symbol: "display.2", title: L("Open System Display Arrangement…"), kind: .action) {
                SystemSettings.openDisplayArrangement()
            }
        }
    }

    private func moveButton(_ symbol: String, dx: CGFloat, dy: CGFloat) -> some View {
        Button {
            _ = DisplayControl.translate(device, by: CGPoint(x: dx, y: dy))
            DisplayManager.shared.refresh()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
        }
        .buttonStyle(.plain)
    }

    private var imageAdjustments: some View {
        VStack(alignment: .leading, spacing: 6) {
            PanelSliderRow(
                caption: model.brightnessCaption(for: device),
                valueText: model.brightnessLabel(device),
                symbol: "sun.max.fill",
                value: Binding(
                    get: { model.brightness(device) },
                    set: { model.setBrightness($0, device) }
                )
            )

            PanelSliderRow(
                caption: L("Contrast (DDC)"),
                valueText: device.contrast.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                symbol: "circle.lefthalf.filled",
                value: Binding(
                    get: { device.contrast ?? 0.5 },
                    set: { value in
                        device.contrast = value
                        DDCService.shared.setContrast(value, for: device) { ok in
                            if !ok { device.contrast = nil }
                        }
                    }
                ),
                isEnabled: device.ddcAvailable
            )

            if !device.ddcAvailable {
                Text(L("Contrast needs DDC/CI. This display does not answer on its I2C bus."))
                    .font(PanelMetrics.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var deviceControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.brightnessExplanation(for: device))
                .font(PanelMetrics.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(model.volumeExplanation(for: device))
                .font(PanelMetrics.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PanelRow(
                symbol: "bolt.horizontal",
                title: device.isBuiltIn ? L("Built-in display has no DDC bus") : L("Re-probe DDC"),
                kind: .action,
                isEnabled: !device.isBuiltIn
            ) {
                model.probeDDC(device)
            }
        }
    }

    private var inputSourceList: some View {
        VStack(spacing: 0) {
            if model.inputSource(device) == nil {
                Text(L("This display did not answer the input-source query (VCP 0x60)."))
                    .font(PanelMetrics.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.bottom, 4)
            }
            ForEach(DDCService.InputSource.allCases, id: \.rawValue) { source in
                PanelRow(
                    symbol: "",
                    title: source.label,
                    kind: .action,
                    isSelected: model.inputSource(device) == source
                ) {
                    model.selectInputSource(source, for: device)
                    onBack()
                }
            }
        }
    }

    private var manageDisplay: some View {
        VStack(spacing: 0) {
            if Preferences.connectOptions {
                PanelRow(
                    symbol: "power",
                    title: model.isEnabled(device) ? L("Disconnect") : L("Connect"),
                    kind: .action,
                    isEnabled: model.canDisconnect(device)
                ) {
                    model.setEnabled(device, !model.isEnabled(device))
                    onBack()
                }
            }

            PanelRow(
                symbol: "m.circle",
                title: L("Set as Main Display"),
                kind: .action,
                isEnabled: !model.isMain(device)
            ) {
                model.setMainDisplay(device)
                onBack()
            }

            PanelRow(symbol: "gearshape", title: L("Open Display Settings…"), kind: .action) {
                SystemSettings.openDisplays()
            }

            if !model.canDisconnect(device) {
                Text(L("Disconnecting this display is not available: it is the built-in panel."))
                    .font(PanelMetrics.captionFont)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.top, 2)
            }
        }
    }

    /// Colour profiles: the list is real, applying is refused by macOS.
    private var colourProfile: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let current = ColorService.currentProfileURL(device.id) {
                Text(L("Current: %@", current.deletingPathExtension().lastPathComponent))
                    .font(PanelMetrics.captionFont)
                    .foregroundStyle(.secondary)
            }
            Text(ColorService.writeRefusalReason)
                .font(PanelMetrics.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            PanelRow(symbol: "paintpalette", title: L("Open Color Profile Settings…"), kind: .action) {
                SystemSettings.openDisplaysColorProfile()
            }
        }
    }

    /// Start/stop for the capture pipeline. The window is the same in both cases; the
    /// difference is whether it floats above everything (PiP) or behaves like a normal window.
    private func streamControls(floating: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            PanelRow(
                symbol: model.isStreaming(device) ? "stop.fill" : "play.rectangle",
                title: model.isStreaming(device)
                    ? L("Stop Capture")
                    : (floating ? L("Open Picture in Picture") : L("Open Stream Window")),
                kind: .action
            ) {
                model.togglePictureInPicture(device)
                onBack()
            }

            Text(L("ScreenCaptureKit captures this display's framebuffer at its own resolution. No Metal compositor and no crop editor yet, so HDR and protected video may not look right."))
                .font(PanelMetrics.captionFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)

            if !StreamService.hasPermission {
                PanelRow(symbol: "lock.shield", title: L("Grant Screen Recording…"), kind: .action) {
                    StreamService.requestPermission()
                }
            }
        }
    }

    private func unavailableNote(_ text: String) -> some View {
        Text(text)
            .font(PanelMetrics.captionFont)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
    }

    /// Why a row has nothing behind it yet, stated per row rather than as one blanket
    /// "not implemented".
    private var reason: String {
        switch submenu {
        case .colorMode:
            return L("Color mode switching needs DDC/CI (VCP 0x08) and this display does not answer on its bus.")
        case .stream:
            return L("Streaming needs a capture pipeline (ScreenCaptureKit plus a Metal compositor). Not in this build — the physical display keeps driving itself for now.")
        case .pip:
            return L("Picture in picture is the stream pipeline with a second window. It lands with streaming, not before it.")
        case .colorProfile:
            return L("Color profile switching goes through ColorSync, which needs the display's UUID. This build reads the profile but does not write one yet.")
        case .protection:
            return L("Configuration protection locks the current mode and layout against outside changes. The display layer can snapshot a configuration; the lock is not wired yet.")
        case .rotation:
            return L("Rotation is reported but not driven: there is no public setter, and the private SkyLight entry points this system exports do not include one.")
        default:
            return ""
        }
    }

    private func isCurrent(_ mode: DisplayModeInfo) -> Bool {
        guard let current = device.currentMode else { return false }
        return current.width == mode.width
            && current.height == mode.height
            && current.isHiDPI == mode.isHiDPI
    }
}
