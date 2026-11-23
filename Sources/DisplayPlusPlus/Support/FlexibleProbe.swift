import AppKit
import CoreGraphics
import Foundation

/// Drives flexible scaling from the command line so the sequence can be verified
/// without touching the menu.
///
///   display++ --flex-hidpi 2         synthesise and switch the panel to 1600×900 · 2x
///   display++ --flex-hidpi 2 off     switch it back and release the virtual display
@MainActor
enum FlexibleProbe {
    static func run(_ arguments: [String]) {
        let manager = DisplayManager.shared
        manager.start()

        let numbers = arguments.dropFirst().compactMap { UInt32($0) }
        let wanted = numbers.first
        guard let device = wanted.flatMap({ manager.device(for: $0) }) ?? manager.devices.first(where: { !$0.isBuiltIn }) else {
            print("no display")
            exit(1)
        }

        let scaling = FlexibleScaling.shared
        let off = arguments.contains("off")

        print("flexible hidpi: \(device.name) id=\(device.id)")
        print("  available   \(scaling.isAvailable)")
        print("  before      \(device.currentMode?.fullLabel ?? "nil") pix=\(device.currentMode?.pixelWidth ?? 0) slider=\(String(format: "%.3f", device.resolutionSliderValue)) choices=\(device.sliderChoices.count)")

        let started = Date()
        let ok = off ? scaling.disable(for: device) : scaling.enable(for: device)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        manager.refresh()
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        let after = manager.device(for: device.id)?.currentMode

        print("  result      ok=\(ok) \(elapsed)ms")
        print("  after       \(after?.fullLabel ?? "nil") pix=\(after?.pixelWidth ?? 0) active=\(CGDisplayIsActive(device.id)) online=\(CGDisplayIsOnline(device.id))")
        let frames = NSScreen.screens.map { "\(Int($0.frame.width))x\(Int($0.frame.height)) scale=\(Int($0.backingScaleFactor))" }.joined(separator: " | ")
        print("  holding     virtual=\(scaling.isActive(for: device.id)) screens=\(NSScreen.screens.count) bounds=\(CGDisplayBounds(device.id))")
        print("  screens     \(frames)")
        print("  panel mode  \(after?.fullLabel ?? "nil") points=\(after?.sizeLabel ?? "?") backing=\(after.map { "\($0.pixelWidth)x\($0.pixelHeight)" } ?? "?")")
        if let live = manager.device(for: device.id) {
            print("  slider      \(String(format: "%.3f", live.resolutionSliderValue)) choices=\(live.sliderChoices.count)")
        }

        // `toggle` exercises the round trip inside one process: the virtual display has
        // to stay held while 2x is on, so a second process cannot verify the way back.
        if arguments.contains("toggle"), !off, ok {
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let back = scaling.disable(for: device)
            manager.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let restored = manager.device(for: device.id)?.currentMode
            print("  back        ok=\(back) \(restored?.fullLabel ?? "nil") pix=\(restored?.pixelWidth ?? 0) active=\(CGDisplayIsActive(device.id)) holding=\(scaling.isActive(for: device.id))")
        }
        exit(ok ? 0 : 2)
    }
}
