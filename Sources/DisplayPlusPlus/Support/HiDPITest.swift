import AppKit
import CoreGraphics

/// Verifies the HiDPI row.
///
/// The target behaviour is not "pick another mode from the list CoreGraphics gives us" —
/// it is "keep the point size, double the backing store". On the 1080p panel that means
/// `1600 × 900` points over a `3200 × 1800` framebuffer, which only exists in the window
/// server's own mode table.
enum HiDPIScaleTest {
    static func run(_ arguments: [String]) {
        DisplayManager.shared.start()
        let manager = DisplayManager.shared

        let wanted: CGDirectDisplayID? = arguments.count > 1 ? UInt32(arguments[1]) : nil
        guard let device = wanted.flatMap({ manager.device(for: $0) }) ?? manager.devices.first(where: { !$0.isBuiltIn }) ?? manager.devices.first else {
            print("no display"); return
        }

        func snapshot(_ label: String) {
            let mode = CGDisplayCopyDisplayMode(device.id)
            let point = mode.map { "\($0.width) × \($0.height)" } ?? "—"
            let pixels = mode.map { "\($0.pixelWidth) × \($0.pixelHeight)" } ?? "—"
            let scale = mode.map { Double($0.pixelWidth) / Double(max(1, $0.width)) } ?? 0
            print(String(format: "%-10@ points=%@ pixels=%@ scale=%.2f", label as NSString, point, pixels, scale))
        }

        print("display        \(device.name) (id \(device.id))")
        print("cgs table      \(DisplayModeTable.isAvailable ? "available" : "unavailable"), \(DisplayModeTable.modes(for: device.id).count) modes")
        let twins = DisplayModeTable.hiDPITwins(of: device.id, width: device.currentMode?.width ?? 0, height: device.currentMode?.height ?? 0)
        print("2x twins       \(twins.map { "#\($0.number) \($0.width)×\($0.height) pix=\($0.pixelWidth)×\($0.pixelHeight)" }.joined(separator: ", "))")
        print("candidates     \(manager.hiDPICandidates(of: device).map(\.fullLabel).joined(separator: ", "))")
        snapshot("before")

        // Re-read the device after each toggle: `refresh()` replaces the objects, and the
        // old one still describes the previous mode.
        let on = manager.toggleHiDPI(device)
        usleep(1_200_000)
        snapshot("toggled")

        let refreshed = manager.device(for: device.id) ?? device
        let off = manager.toggleHiDPI(refreshed)
        usleep(1_200_000)
        snapshot("restored")

        let beforeHadHiDPI = twins.isEmpty == false
        print("result         on=\(on) off=\(off) twinsKnown=\(beforeHadHiDPI)")
    }
}
