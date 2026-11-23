import AppKit
import CoreGraphics

/// Colour-profile diagnostics. Runs in a GUI process when `DPP_COLOR_TEST=1`, because the
/// write path behaves differently (returns false either way here, but the reader needs
/// ColorSync to be initialised the same way the app initialises it).
enum ColourProfileTest {
    static func run() {
        print("colour profiles")
        print(String(repeating: "=", count: 56))
        for device in DisplayManager.shared.devices {
            print("\(device.name) (id \(device.id))")
            let current = ColorService.currentProfileURL(device.id)
            print("  current: \(current?.lastPathComponent ?? "—")")
            let list = ColorService.profiles(for: device.id)
            print("  available: \(list.count) (\(list.prefix(3).map(\.name).joined(separator: ", ")) …)")
            guard let target = list.first(where: { !$0.isFactory && $0.name.contains("Sepia") }) ?? list.first(where: { !$0.isFactory }) else {
                print("  no candidate"); continue
            }
            let ok = ColorService.apply(target.url, to: device.id)
            let after = ColorService.currentProfileURL(device.id)
            print("  apply \(target.name): ok=\(ok) now=\(after?.lastPathComponent ?? "—")")
            if let current { _ = ColorService.apply(current, to: device.id) }
            print("  restored: \(ColorService.currentProfileURL(device.id)?.lastPathComponent ?? "—")")
        }
    }

    static func writeFailureLine() -> String {
        ColorService.writeRefusalReason
    }
}
