import SwiftUI

/// The slider used in the panel: 4 pt track, 18 pt white knob with a soft
/// shadow, no tick marks. The stock `NSSlider` is not usable here — its knob is
/// 20 pt and its track takes the accent colour, which reads as a different control.
///
/// `steps` drives snapping: resolution is a discrete list, brightness is
/// continuous, and both go through the same control so the rows line up.
struct AppSlider: View {
    @Binding var value: Double
    var steps: Int? = nil
    var isEnabled: Bool = true
    var onEditingChanged: (Bool) -> Void = { _ in }

    @StateObject private var drag = StateBox(false)

    private var isDragging: Bool { drag.value }

    private let trackHeight: CGFloat = 4
    private let knobSize: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let usable = max(1, geo.size.width - knobSize)
            let knobX = CGFloat(clamped(value)) * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.16))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(Color.primary.opacity(0.38))
                    .frame(width: knobX + knobSize / 2, height: trackHeight)

                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: .black.opacity(0.22), radius: 2.5, y: 1)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.06), lineWidth: 0.5))
                    .scaleEffect(isDragging ? 1.06 : 1)
                    .offset(x: knobX)
                    .animation(.easeOut(duration: 0.12), value: isDragging)
            }
            .frame(height: knobSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        guard isEnabled else { return }
                        if !drag.value {
                            drag.value = true
                            onEditingChanged(true)
                        }
                        set(fromX: gesture.location.x, usable: usable)
                    }
                    .onEnded { _ in
                        drag.value = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: knobSize)
        .opacity(isEnabled ? 1 : 0.4)
        .allowsHitTesting(isEnabled)
    }

    private func set(fromX x: CGFloat, usable: CGFloat) {
        var next = Double(min(max((x - knobSize / 2) / usable, 0), 1))
        if let steps, steps > 1 {
            next = (next * Double(steps - 1)).rounded() / Double(steps - 1)
        }
        value = next
    }

    private func clamped(_ raw: Double) -> Double { min(max(raw, 0), 1) }
}
