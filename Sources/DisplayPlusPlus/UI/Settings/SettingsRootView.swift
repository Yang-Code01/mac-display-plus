import AppKit
import SwiftUI

/// The settings window: sidebar plus pane.
///
/// Measured rather than guessed (800 × 600 content, 195 pt sidebar rows at 34 pt
/// pitch, seven panes: Displays / Display Groups / Apps / Menu / Keyboard / Pro /
/// About, with a "Show help" switch and three footer links).
enum SettingsPane: String, CaseIterable, Identifiable {
    case displays
    case groups
    case apps
    case menu
    case keyboard
    case pro
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .displays: return L("Displays")
        case .groups: return L("Display Groups")
        case .apps: return L("Apps")
        case .menu: return L("Menu")
        case .keyboard: return L("Keyboard")
        case .pro: return L("Pro")
        case .about: return L("About")
        }
    }

    var symbol: String {
        switch self {
        case .displays: return "display.2"
        case .groups: return "rectangle.split.2x1"
        case .apps: return "app.badge"
        case .menu: return "filemenu.and.selection"
        case .keyboard: return "keyboard"
        case .pro: return "checkmark.seal"
        case .about: return "tag"
        }
    }
}

/// Root of the settings window.
struct SettingsRootView: View {
    @ObservedObject var model: PanelModel
    @StateObject private var pane = StateBox<SettingsPane>(.displays)
    @StateObject private var helpShown = StateBox(true)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().opacity(0.4)
            detail
        }
        .frame(minWidth: 800, minHeight: 600)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 2) {
                ForEach(SettingsPane.allCases) { item in
                    sidebarRow(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 18)

            Spacer(minLength: 8)

            HStack {
                Text(L("Show help"))
                    .font(.system(size: 12))
                Spacer()
                MiniSwitch(isOn: $helpShown.value)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 6) {
                footerLink("arrow.right.circle", L("App Menu")) {
                    // Opening the panel is the app menu's job; from here it would be
                    // a no-op, so the link explains itself instead of doing nothing.
                }
                footerLink("book", L("Guide")) { SystemSettings.openDisplays() }
                footerLink("globe", L("简体中文")) { SystemSettings.openLanguage() }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 14)
        }
        .frame(width: 195)
    }

    private func sidebarRow(_ item: SettingsPane) -> some View {
        Button {
            pane.value = item
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(pane.value == item ? Color.accentColor : .secondary)
                    .frame(width: 20)
                Text(item.title)
                    .font(.system(size: 13))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(pane.value == item ? Color.primary.opacity(0.10) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func footerLink(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11))
                Text(title).font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane.value {
        case .displays: DisplaysPane(model: model)
        case .groups: GroupsPane(model: model)
        case .apps: AppsPane(model: model)
        case .menu: MenuPane(model: model)
        case .keyboard: KeyboardPane(model: model)
        case .pro: ProPane()
        case .about: AboutPane()
        }
    }
}

// MARK: - Shared settings controls

/// A switch bound to a `Preferences` key.
///
/// The settings UI used to keep its own `@State`, so a toggle meant "this view thinks so".
/// Every one of these is now a real preference with a consumer.
func prefBinding(_ key: Preferences.Key, default fallback: Bool) -> Binding<Bool> {
    Binding(
        get: { Preferences.bool(key, default: fallback) },
        set: { Preferences.set(key, $0) }
    )
}

/// A grouped card, the shape macOS 26 Settings uses: rounded rectangle, rows divided
/// by hairlines, title + explanatory subtitle on the left and one control on the right.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.055))
            )
    }
}

/// One row inside a card.
struct SettingsRow<Trailing: View>: View {
    var title: String
    var subtitle: String? = nil
    var symbol: String? = nil
    var symbolColor: Color = .accentColor
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(symbolColor)
                        .frame(width: 18, height: 18)
                }
                Text(title)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                trailing
            }
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 7)
    }
}

/// A secondary action button in the settings style.
struct SettingsButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.10))
                )
        }
        .buttonStyle(.plain)
    }
}
