import SwiftUI

/// The switch in a device header.
///
/// `Toggle(.switch)` is close but not the same: its track is 4 pt taller, and it
/// draws the accent colour only when on, whereas the off state needs to be a
/// translucent grey that reads correctly over glass. Drawing it also keeps
/// `ImageRenderer` output faithful, which the stock control is not.
struct MiniSwitch: View {
    @Binding var isOn: Bool
    var help: String = ""

    private let width: CGFloat = 27
    private let height: CGFloat = 15
    private let knob: CGFloat = 13

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.14)) { isOn.toggle() }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor : Color.primary.opacity(0.14))
                    .overlay(
                        Capsule().strokeBorder(
                            isOn ? Color.clear : Color.primary.opacity(0.10),
                            lineWidth: 0.5
                        )
                    )

                Circle()
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.18), radius: 1, y: 0.5)
                    .frame(width: knob, height: knob)
                    .padding(1)
            }
            .frame(width: width, height: height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help.isEmpty ? L("Switch") : help)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}
