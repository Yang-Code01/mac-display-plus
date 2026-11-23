import AppKit
import CoreGraphics
import Foundation

/// Flexible HiDPI: a 2x-backed mode for a panel that cannot run one itself.
///
/// A 1080p panel cannot show `1600 × 900 · 2x`, because that needs a 3200×1800
/// framebuffer and the panel's own mode list stops at 1920×1080. The window server
/// will still *compose* one for it — but only while a virtual display that declares
/// that mode exists and the panel is mirroring it. Once the mode has been synthesised
/// it can be bound to the panel in the same transaction that drops the mirror, and the
/// panel then renders at 3200×1800 and the GPU scales the result down to its 1080p
/// panel. Measured on this machine (AOC 2490W1 over DP→HDMI, macOS 27.2):
///
///     mirror panel -> virtual(1600×900 hiDPI)     active2=0
///     panel mode list while mirrored             1600×900 pix=3200   ← synthesised
///     one transaction: clear mirror + bind mode   clear=0 bind=0 complete=0
///     panel now                                  1600×900 pix=3200 active=1 online=1
///
/// Two consequences drive the design:
///
/// * The virtual display has to stay alive for as long as the panel uses that mode.
///   Destroying it flushes the synthesised mode and the panel falls back to 1x, which
///   is also what happens when the process exits.
/// * Dropping the mirror on its own (`CGCompleteDisplayConfiguration` returns 1001)
///   flushes the mode before it can be bound, so the clear and the bind have to be
///   one transaction.
final class FlexibleScaling {
    static let shared = FlexibleScaling()

    /// What is currently held for each display, so it can be released exactly once.
    private struct Held {
        let virtualID: CGDirectDisplayID
        let width: Int
        let height: Int
    }

    private var held: [CGDirectDisplayID: Held] = [:]

    var isAvailable: Bool { VirtualScreenService.shared.isAvailable }

    func isActive(for id: CGDirectDisplayID) -> Bool { held[id] != nil }

    /// Gives `device` a 2x-backed mode at its current size and switches it there.
    ///
    /// The panel goes blank for a moment while it is mirrored onto the virtual display;
    /// that is unavoidable — the mirror is what makes the window server synthesise the
    /// mode in the first place.
    @discardableResult
    func enable(for device: DisplayDevice) -> Bool {
        guard let current = device.currentMode else { return false }
        // Already 2x (or nothing to scale): nothing to do.
        guard !current.isHiDPI else { return true }

        let width = current.width
        let height = current.height
        guard width > 0, height > 0 else { return false }

        release(for: device.id)

        // A mirror round trip re-anchors displays; remember where everything was.
        let arrangement = DisplayManager.Arrangement.capture()

        let service = VirtualScreenService.shared
        service.forceEnabled = true
        guard service.create(width: width, height: height, name: "display++ \(width)×\(height) 2x", hiDPI: true),
              let virtualID = service.createdIDs.last else { return false }

        defer { refresh() }

        // Mirror the panel onto the virtual display first: the synthesised mode only
        // appears in the panel's list *while* it is mirroring. Creating the virtual
        // display on its own leaves the panel's mode list untouched (measured).
        var mirror: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&mirror) == .success else {
            service.remove(id: virtualID)
            return false
        }
        _ = CGConfigureDisplayMirrorOfDisplay(mirror, device.id, virtualID)
        _ = CGCompleteDisplayConfiguration(mirror, .forSession)

        guard let scaled = waitForScaledMode(display: device.id, width: width, height: height) else {
            restore(device.id, width: width, height: height)
            service.remove(id: virtualID)
            return false
        }

        // One transaction: drop the mirror and bind the synthesised mode.
        var bind: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&bind) == .success else {
            restore(device.id, width: width, height: height)
            service.remove(id: virtualID)
            return false
        }
        _ = CGConfigureDisplayMirrorOfDisplay(bind, device.id, kCGNullDirectDisplay)
        let bound = CGConfigureDisplayWithDisplayMode(bind, device.id, scaled, nil)
        let done = CGCompleteDisplayConfiguration(bind, .permanently)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))

        let landed = CGDisplayCopyDisplayMode(device.id).map { $0.pixelWidth == width * 2 } ?? false
        guard bound == .success, done == .success, landed else {
            restore(device.id, width: width, height: height)
            service.remove(id: virtualID)
            return false
        }
        // Keep the helper out of the user's layout: mirror the virtual display onto the
        // panel. Without this it stays a third desktop that renders nothing and pushes
        // the panel's origin sideways (measured: panel moved to -1600 and NSScreen
        // reported 3 screens).
        var hide: CGDisplayConfigRef?
        if CGBeginDisplayConfiguration(&hide) == .success {
            _ = CGConfigureDisplayMirrorOfDisplay(hide, virtualID, device.id)
            _ = CGCompleteDisplayConfiguration(hide, .forSession)
        }
        restoreArrangement(arrangement)

        held[device.id] = Held(virtualID: virtualID, width: width, height: height)
        return true
    }

    /// Switches the panel back to its plain 1x mode and releases the virtual display.
    @discardableResult
    func disable(for device: DisplayDevice) -> Bool {
        let ok = restore(device.id, width: held[device.id]?.width ?? device.currentMode?.width ?? 0,
                         height: held[device.id]?.height ?? device.currentMode?.height ?? 0)
        release(for: device.id)
        refresh()
        return ok
    }

    func releaseAll() {
        for id in held.keys { release(for: id) }
    }

    // MARK: - Steps

    private func refresh() {
        DisplayManager.shared.refresh()
    }

    private func release(for id: CGDirectDisplayID) {
        guard let entry = held.removeValue(forKey: id) else { return }
        VirtualScreenService.shared.remove(id: entry.virtualID)
    }

    /// The scaled twin only exists while the virtual display is alive, and the window
    /// server needs a moment to publish it in the panel's mode list.
    private func waitForScaledMode(display id: CGDirectDisplayID, width: Int, height: Int) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        for _ in 0..<10 {
            let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
            if let scaled = modes.first(where: {
                $0.width == width && $0.height == height && $0.pixelWidth == width * 2
            }) {
                return scaled
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return nil
    }

    /// Puts every display back where the user had it.
    ///
    /// Clearing a mirror makes the window server re-anchor the panel on the edge it
    /// shares with the helper display, which moved this panel from x=1440 to x=-1600 —
    /// a mirror round trip is not allowed to rearrange the desk.
    private func restoreArrangement(_ arrangement: DisplayManager.Arrangement) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        arrangement.restore()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }

    @discardableResult
    private func restore(_ id: CGDirectDisplayID, width: Int, height: Int) -> Bool {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
        guard let plain = modes.first(where: {
            $0.width == width && $0.height == height && $0.pixelWidth == width
        }) ?? modes.first else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        _ = CGConfigureDisplayMirrorOfDisplay(config, id, kCGNullDirectDisplay)
        _ = CGConfigureDisplayWithDisplayMode(config, id, plain, nil)
        let done = CGCompleteDisplayConfiguration(config, .permanently)
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        return done == .success
    }
}
