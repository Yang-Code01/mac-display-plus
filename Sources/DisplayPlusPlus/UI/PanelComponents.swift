import AppKit
import SwiftUI

/// Panel metrics, measured rather than guessed.
///
/// The open panel measures 378 × 873 (`AXWindow`) with a 280 pt content column,
/// 24 pt menu rows and 16 pt switches. The numbers below are the content column;
/// the extra width in that figure is the window shadow.
enum PanelMetrics {
    static let panelWidth: CGFloat = 300
    static let outerPadding: CGFloat = 8
    static let blockSpacing: CGFloat = 8
    static let blockCornerRadius: CGFloat = 18
    static let innerPadding: CGFloat = 10

    /// Menu rows: 24 pt tall, one row per unit, so they stack without gaps.
    static let rowHeight: CGFloat = 24
    /// Header rows (display name, tools, footer buttons) are 32 pt.
    static let headerHeight: CGFloat = 32

    static let iconSize: CGFloat = 15
    static let headerIconSize: CGFloat = 17
    static let sliderKnob: CGFloat = 18
    static let sliderTrack: CGFloat = 4

    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let rowFont = Font.system(size: 13)
    static let captionFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 13).monospacedDigit()
}

/// A menu row: leading symbol, label, optional value, optional chevron.
///
/// A row carries a chevron when it opens a submenu and none when it is an action or
/// a switch, so the presence of the chevron is the affordance. That is why `kind`
/// exists rather than a flag per call site.
struct PanelRow: View {
    enum Kind {
        case submenu
        case action
    }

    var symbol: String
    var title: String
    var kind: Kind = .submenu
    var value: String? = nil
    var isEnabled: Bool = true
    var isSelected: Bool = false
    var symbolColor: Color = .secondary
    let action: () -> Void

    @StateObject private var hover = StateBox(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(symbolColor)
                    .frame(width: PanelMetrics.iconSize, height: PanelMetrics.iconSize)

                Text(title)
                    .font(PanelMetrics.rowFont)
                    .foregroundStyle(isEnabled ? Color.primary : Color.primary.opacity(0.35))
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let value {
                    Text(value)
                        .font(PanelMetrics.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                if kind == .submenu {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 6)
            .frame(height: PanelMetrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hover.value && isEnabled ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hover.value = $0 }
    }
}

/// One slider block: caption on the left, value on the right, then the control.
///
/// Caption and value sit on separate rows above the track, so this is not a
/// single `Toggle`-style row.
struct PanelSliderRow: View {
    var caption: String
    var valueText: String
    var symbol: String
    @Binding var value: Double
    var isEnabled: Bool = true
    /// Trailing badge on the caption row, e.g. the mute button.
    var trailing: AnyView? = nil
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(caption)
                    .font(PanelMetrics.rowFont)
                    .foregroundStyle(isEnabled ? Color.primary : Color.primary.opacity(0.35))
                Spacer(minLength: 4)
                if let trailing { trailing }
                Text(valueText)
                    .font(PanelMetrics.valueFont)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, alignment: .center)

                AppSlider(value: $value, isEnabled: isEnabled, onEditingChanged: onEditingChanged)
                    .frame(height: 22)
            }
        }
    }
}

/// A section title inside a block ("Tools", "Brightness"), 13 pt semibold.
struct PanelSectionTitle: View {
    var text: String

    var body: some View {
        Text(text)
            .font(PanelMetrics.titleFont)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .padding(.bottom, 2)
    }
}

/// The centred chevron that collapses a display block.
struct PanelCollapseChevron: View {
    var isCollapsed: Bool
    var action: () -> Void

    @StateObject private var hover = StateBox(false)

    var body: some View {
        Button(action: action) {
            Image(systemName: isCollapsed ? "chevron.down" : "chevron.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hover.value ? Color.primary : Color.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .help(isCollapsed ? L("Expand") : L("Collapse"))
    }
}

/// The blue full-width primary button at the top of a display block
/// ("Configure Device Control…").
struct PanelProminentButton: View {
    var title: String
    var symbol: String
    var action: () -> Void

    @StateObject private var hover = StateBox(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 23)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(hover.value ? 0.85 : 1))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
    }
}
