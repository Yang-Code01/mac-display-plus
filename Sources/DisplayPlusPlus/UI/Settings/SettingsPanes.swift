import AppKit
import SwiftUI

// MARK: - Displays

/// The Displays pane: a tab strip (Overview plus one tab per display) over the
/// settings for whichever is selected.
///
/// A top tab strip, for exactly this reason: per-display settings do not fit in a
/// list of displays, and a drill-down loses the comparison.
struct DisplaysPane: View {
    @ObservedObject var model: PanelModel
    @StateObject private var selected = StateBox<UInt32?>(nil)

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let id = selected.value, let device = model.devices.first(where: { $0.id == id }) {
                        DisplayDetailSettings(model: model, device: device)
                    } else {
                        overview
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }
        }
    }

    private var tabStrip: some View {
        HStack(spacing: 0) {
            tab(nil, title: L("Overview"), symbol: "list.bullet")
            ForEach(model.devices) { device in
                tab(device.id,
                    title: device.name,
                    symbol: device.isBuiltIn ? "laptopcomputer" : "display")
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private func tab(_ id: UInt32?, title: String, symbol: String) -> some View {
        let isSelected = selected.value == id
        return Button {
            selected.value = id
        } label: {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .frame(width: 96, height: 62)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                ForEach(model.devices) { device in
                    Button {
                        selected.value = device.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: device.isBuiltIn ? "laptopcomputer" : "display")
                                .font(.system(size: 13))
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.system(size: 13))
                                Text(device.currentMode?.fullLabel ?? "—")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            SettingsCard {
                SettingsRow(
                    title: L("Show currently detached (previously disconnected) displays"),
                    subtitle: L("Lists every display this app has seen before, so its settings can be edited while it is offline.")
                ) {
                    MiniSwitch(isOn: prefBinding(.showDetachedDisplays, default: false))
                }
                if Preferences.showDetachedDisplays {
                    let live = Set(model.devices.map(\.id))
                    let detached = Preferences.detachedDisplays(live: live)
                    if detached.isEmpty {
                        Text(L("No detached displays have been recorded yet."))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(detached, id: \.id) { entry in
                            SettingsRow(title: entry.name,
                                        subtitle: L("Offline — seen before, not connected now. Settings can be staged.")) {
                                Text(L("Offline"))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                SettingsRow(title: L("Advanced display settings"),
                            subtitle: L("EDID overrides and custom timing are not implemented in this build.")) {
                    SettingsButton(title: L("Advanced…")) { SystemSettings.openDisplays() }
                }
            }

            SettingsCard {
                SettingsRow(title: L("Virtual screens"),
                            subtitle: L("Virtual screens behave like real displays but live in memory. They can be mirrored, streamed or captured.")
                ) {
                    SettingsButton(title: L("New Virtual Screen…")) { }
                        .disabled(true)
                        .help(L("Not wired up in this build: the private initialiser rejects the descriptor and throws, which would take the app down."))
                }
                SettingsRow(title: L("Advanced virtual screen settings"),
                            subtitle: L("Resolution, HiDPI scale and rotation of the virtual screen's framebuffer.")) {
                    SettingsButton(title: L("Advanced…")) { }
                        .disabled(true)
                }
            }

            SettingsCard {
                SettingsRow(
                    title: L("Enable connect and disconnect options for displays"),
                    subtitle: L("Adds the connect switch to each display's header and a Disconnect row to its menu. Disconnecting puts the display to sleep and removes it from the layout.")
                ) {
                    MiniSwitch(isOn: prefBinding(.connectOptions, default: true))
                }
            }

            SettingsCard {
                // Not wired: software XDR needs a color table path this build does not have.
                // Offered as a disabled row with the reason, instead of a switch that looks
                // live and changes nothing.
                SettingsRow(title: L("Software XDR/HDR brightness boost and dimming"),
                            subtitle: L("Not wired in this build: software XDR needs the color table path. Brightness above 100% is not offered rather than faked with gamma.")) {
                    MiniSwitch(isOn: .constant(false)).disabled(true)
                }
                SettingsRow(title: L("Allow color table adjustments"),
                            subtitle: L("Not wired in this build. Image adjustments currently go through the gamma table, which needs no color table control.")) {
                    MiniSwitch(isOn: .constant(true)).disabled(true)
                }
            }
        }
    }
}

/// Per-display settings, opened from a tab or from the overview list.
struct DisplayDetailSettings: View {
    @ObservedObject var model: PanelModel
    let device: DisplayDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SettingsCard {
                SettingsRow(title: L("Brightness"),
                            subtitle: model.brightnessExplanation(for: device)) {
                    Text(model.brightnessLabel(device))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                SettingsRow(title: L("Volume"),
                            subtitle: model.volumeExplanation(for: device)) {
                    Text(model.isMuted(device) ? L("Muted") : model.volumeLabel(device))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                SettingsRow(title: L("Resolution"),
                            subtitle: device.currentMode.map { L("Mode %@ at %.0f Hz", $0.fullLabel, $0.refreshRate) }) {
                    SettingsButton(title: L("Change…")) {
                        _ = model.stepResolution(device, by: 1)
                    }
                }
            }

            SettingsCard {
                SettingsRow(title: L("High Resolution (HiDPI)"),
                            subtitle: model.canToggleHiDPI(device)
                                ? L("Switches to the HiDPI twin of the current size: same layout, twice the pixels, no output timing change.")
                                : model.hiDPIUnavailableText(device)) {
                    MiniSwitch(
                        isOn: Binding(
                            get: { device.isHiDPIActive },
                            set: { _ in model.toggleHiDPI(device) }
                        )
                    )
                    .disabled(!model.canToggleHiDPI(device))
                    .opacity(model.canToggleHiDPI(device) ? 1 : 0.4)
                }
                SettingsRow(title: L("Set as Main Display"),
                            subtitle: L("Moves the menu bar to this display by translating the whole arrangement so it sits at the origin.")) {
                    MiniSwitch(
                        isOn: Binding(
                            get: { model.isMain(device) },
                            set: { if $0 { model.setMainDisplay(device) } }
                        )
                    )
                }
                SettingsRow(title: L("Connect"),
                            subtitle: model.canDisconnect(device)
                                ? L("Disconnecting puts the display to sleep and removes it from the layout.")
                                : L("The built-in panel cannot be disconnected.")) {
                    MiniSwitch(
                        isOn: Binding(
                            get: { model.isEnabled(device) },
                            set: { model.setEnabled(device, $0) }
                        )
                    )
                    .disabled(!model.canDisconnect(device))
                }
            }

            SettingsCard {
                SettingsRow(title: L("Input Source"),
                            subtitle: model.inputSource(device).map { L("Currently %@", $0.label) }
                                ?? L("This display did not answer the input-source query (VCP 0x60).")) {
                    SettingsButton(title: L("Re-query")) { model.refreshInputSource(device) }
                }
                SettingsRow(title: L("Screen Rotation"),
                            subtitle: L("Rotation is reported but not driven: there is no public setter, and the private SkyLight entry points this system exports do not include one.")) {
                    Text(model.rotationLabel(device))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Display groups

struct GroupsPane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        PaneScaffold(title: L("Display Groups"), subtitle: L("Displays in a group move together: one slider drives all of them.")) {
            SettingsCard {
                Text(L("No groups yet. The display layer can mirror and arrange displays; group synchronisation is the next layer on top of it."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Apps

struct AppsPane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        PaneScaffold(title: L("Apps"), subtitle: L("Per-app display settings: force a mode, a brightness or a colour profile while an app is in front.")) {
            SettingsCard {
                Text(L("Nothing configured. App rules need the display layer's mode API, which exists; the rule editor does not."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }
}

// MARK: - Menu

/// Which rows the app menu shows. Every row is a real menu row, so the toggles are
/// backed by `AppMenuLayout` rather than being decorative.
struct MenuPane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        PaneScaffold(title: L("Menu"), subtitle: L("Choose what the app menu and its display rows contain.")) {
            SettingsCard {
                ForEach(AppMenuSubmenu.allCases, id: \.self) { submenu in
                    SettingsRow(title: submenu.title) {
                        MiniSwitch(isOn: Binding(
                            get: { Preferences.menuRowEnabled(submenu) },
                            set: { Preferences.setMenuRow(submenu, $0); model.objectWillChange.send() }
                        ))
                    }
                }
            }
        }
    }
}

// MARK: - Keyboard

struct KeyboardPane: View {
    @ObservedObject var model: PanelModel

    var body: some View {
        PaneScaffold(title: L("Keyboard"), subtitle: nil) {
            SettingsCard {
                SettingsRow(
                    title: L("Use native brightness keys for brightness control"),
                    subtitle: L("Lets the app consume the Apple brightness keys so they can drive external displays, XDR boost and extra dimming as well."),
                    symbol: "sun.max",
                    symbolColor: .white
                ) {
                    MiniSwitch(isOn: prefBinding(.nativeBrightnessKeys, default: true))
                }
                SettingsRow(title: Accessibility.isGranted
                            ? L("Accessibility is granted — the key tap is installed.")
                            : L("Accessibility is not granted — the keys keep their system behaviour."),
                            symbol: Accessibility.isGranted ? "checkmark.circle" : "xmark.circle",
                            symbolColor: Accessibility.isGranted ? .secondary : .orange) {
                    SettingsButton(title: L("Open Privacy…")) { Accessibility.openSettings() }
                }
            }

            SettingsCard {
                SettingsRow(
                    title: L("Listen for native volume keys"),
                    subtitle: L("Uses the Apple audio keys to drive the selected display's volume instead of the current output device."),
                    symbol: "speaker.wave.2"
                ) {
                    MiniSwitch(isOn: prefBinding(.nativeVolumeKeys, default: false))
                }
            }

            SettingsCard {
                SettingsRow(
                    title: L("On-screen display for adjustments"),
                    subtitle: L("Shows the OSD while changing brightness, volume or mute with the keyboard."),
                    symbol: "circle.square.fill"
                ) {
                    MiniSwitch(isOn: prefBinding(.osdEnabled, default: true))
                }
            }
        }
    }
}

// MARK: - Pro / About

struct ProPane: View {
    var body: some View {
        PaneScaffold(title: L("Pro"), subtitle: nil) {
            SettingsCard {
                Text(L("display++ is free software under the MIT licence. There are no tiers, no trial and no feature flags."))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
    }
}

struct AboutPane: View {
    var body: some View {
        PaneScaffold(title: L("About"), subtitle: nil) {
            SettingsCard {
                SettingsRow(title: L("display++"), subtitle: L("Version %@ — menu bar display control", Probe.appVersion)) {
                    EmptyView()
                }
                SettingsRow(title: L("Method"), subtitle: L("Independent implementation built on the macOS display stack. No code from any other display utility is included.")) {
                    EmptyView()
                }
            }
        }
    }
}

/// Title + scrolling content, shared by the simple panes.
struct PaneScaffold<Content: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Accessibility

enum Accessibility {
    static var isGranted: Bool { AXIsProcessTrusted() }

    static func openSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension SystemSettings {
    static func openLanguage() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}
