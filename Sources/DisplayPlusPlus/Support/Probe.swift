import AppKit
import CoreGraphics
import Foundation

/// Headless verification path. `display++ --probe` prints the same facts the UI
/// renders, so display enumeration and DDC can be checked without trusting a
/// view to be correct.
enum Probe {
    /// Version shown in the About pane, read from the bundle so it cannot drift from
    /// Info.plist.
    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
    }

    static func run() {
        setvbuf(stdout, nil, _IONBF, 0)
        print("display++ probe")
        print(String(repeating: "=", count: 56))

        let manager = DisplayManager.shared
        manager.refresh()

        for device in manager.devices {
            print("")
            print("\(device.name)")
            print("  id            \(device.id)")
            print("  kind          \(device.isBuiltIn ? "built-in" : "external")\(device.isMain ? ", main" : "")")
            print("  av unit       \(device.avUnit.map(String.init) ?? "—")")
            print("  current       \(device.currentMode?.fullLabel ?? "—") @ \(device.currentMode?.refreshRate ?? 0) Hz")
            print("  modes         \(device.modes.count) (\(device.modes.filter(\.isHiDPI).count) HiDPI)")

            let choices = device.resolutionChoices
            print("  resolutions   \(choices.count): " + choices.prefix(8).map(\.fullLabel).joined(separator: ", "))

            if device.isBuiltIn {
                let service = BrightnessService.shared
                let native = service.canControlNatively(device)
                let value = service.nativeLevel(of: device)
                print("  brightness    \(value.map { String(format: "%.0f%%", $0 * 100) } ?? "unavailable") (\(native ? "native" : "software only"))")
            } else {
                let semaphore = DispatchSemaphore(value: 0)
                var result: String = "no reply"
                DDCService.shared.probe(device) { ok in
                    result = ok ? "DDC answering" : "no DDC reply"
                    semaphore.signal()
                }
                _ = semaphore.wait(timeout: .now() + 3)
                print("  ddc           \(result)")
                print("  brightness    via \(result == "DDC answering" ? "ddc (hardware)" : "software dimming (backlight unchanged)")")
                if result == "DDC answering" {
                    let readSem = DispatchSemaphore(value: 0)
                    DDCService.shared.readBrightness(device) { value in
                        print("  ddc brightness \(value.map { String(format: "%.0f%%", $0 * 100) } ?? "—")")
                        readSem.signal()
                    }
                    _ = readSem.wait(timeout: .now() + 3)
                }
            }
        }

        print("")
        print(String(repeating: "=", count: 56))
        print("accessibility   \(MediaKeyTap.hasPermission ? "granted" : "not granted")")
        print("ddc symbols     \(DDCService.shared.isSupported ? "resolved" : "missing")")
        print("modes option    kCGDisplayShowDuplicateLowResolutionModes enabled")
    }
}

/// Verifies the panel actually lays out at a usable size.
///
/// The riskiest part of the UI is the path from SwiftUI's fitting size to a
/// positioned `NSPanel`: a zero or stale size leaves an invisible panel that
/// looks exactly like "the app is broken". `--selftest` exercises it and prints
/// the resulting frame, so that failure mode is observable from a terminal.
@MainActor
enum SelfTest {
    static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let model = PanelModel()
        model.start()
        let controller = AppMenuPanelController(model: model)
        controller.show(relativeTo: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        guard let window = NSApp.windows.first(where: { $0.isVisible }) else {
            print("selftest: panel did not appear")
            exit(1)
        }
        print("selftest: devices=\(model.devices.count)")
        print("selftest: panel frame=\(NSStringFromRect(window.frame)) visible=\(window.isVisible)")
        print("selftest: panel class=\(type(of: window))")
        print("selftest: panel height sane=\(window.frame.height > 80)")
        exit(0)
    }
}

/// End-to-end check of the one feature that matters most: switching a display
/// mode and switching it back.
///
/// `--test-mode` walks selectable modes until one applies, reads back what the
/// window server actually did, then restores the original. It reports the modes
/// CoreGraphics advertised and then refused, because that is a real part of the
/// behaviour and hiding it would make the app look broken.
@MainActor
enum ModeTest {
    static func run() {
        let manager = DisplayManager.shared
        manager.start()
        print("mode test")
        print(String(repeating: "=", count: 56))

        // Control experiment: the same change with nothing but CoreGraphics, in
        // this process. If this succeeds while `apply` fails, the difference is in
        // the manager rather than in process state.
        if let id = manager.devices.first(where: \.isBuiltIn)?.id,
           let current = CGDisplayCopyDisplayMode(id) {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let pool = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode] ?? []
            if let target = pool.first(where: { $0.width != current.width && $0.pixelWidth == $0.width }) {
                let code = CGDisplaySetDisplayMode(id, target, nil)
                print("control   \(current.width)x\(current.height) -> \(target.width)x\(target.height) code=\(code.rawValue)")
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
                _ = CGDisplaySetDisplayMode(id, current, nil)
                RunLoop.current.run(until: Date().addingTimeInterval(0.6))
            }
        }

        for device in manager.devices {
            guard let original = device.currentMode else { continue }
            print("")
            print(device.name)
            print("  before    \(original.fullLabel) @ \(Int(original.refreshRate)) Hz")

            // Re-read candidates each attempt: a refusal is remembered on the
            // device, so the list shrinks as modes are proven unsettable.
            var landed: DisplayModeInfo?
            var refusals: [String] = []
            for _ in 0..<24 {
                guard let candidate = nextCandidate(for: device, away: original) else { break }
                if manager.apply(candidate, to: device) {
                    landed = candidate
                    break
                }
                refusals.append(candidate.fullLabel)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            manager.refresh()
            let after = manager.device(for: device.id)?.currentMode
            print("  switched  \(landed?.fullLabel ?? "none") actual=\(after?.fullLabel ?? "nil")")
            print("  result    \(landed != nil ? "OK" : "FAILED")")
            if !refusals.isEmpty {
                print("  refused   \(refusals.joined(separator: ", "))")
            }

            let restored = manager.apply(original, to: device)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            manager.refresh()
            let back = manager.device(for: device.id)?.currentMode
            post("restore", back, original, restored)
        }
        print("")
        print(String(repeating: "=", count: 56))
        print("done")
    }

    private static func post(_ label: String, _ mode: DisplayModeInfo?, _ want: DisplayModeInfo, _ applied: Bool) {
        let matches = mode.map {
            $0.width == want.width && $0.height == want.height && $0.isHiDPI == want.isHiDPI
        } ?? false
        print("  \(label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(mode?.fullLabel ?? "nil") apply=\(applied) match=\(matches)")
    }

    /// First selectable mode that differs from `current`, preferring a different
    /// scale class so the switch is visible.
    private static func nextCandidate(for device: DisplayDevice, away current: DisplayModeInfo) -> DisplayModeInfo? {
        let choices = device.resolutionChoices.filter {
            !($0.width == current.width && $0.height == current.height && $0.isHiDPI == current.isHiDPI)
        }
        return choices.first(where: { $0.isHiDPI != current.isHiDPI }) ?? choices.first
    }
}


/// `--set-mode <displayID> <WxH>x` applies a mode directly. Also used to put a
/// display back after a test run.
@MainActor
enum SetMode {
    static func run(_ arguments: [String]) {
        guard arguments.count >= 3,
              let id = CGDirectDisplayID(arguments[1]) else {
            print("usage: --set-mode <displayID> <WIDTHxHEIGHT[>]")
            exit(2)
        }
        let spec = arguments[2].trimmingCharacters(in: CharacterSet(charactersIn: ">"))
        let parts = spec.lowercased().split(separator: "x").map(String.init)
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else {
            print("bad mode spec \(spec)")
            exit(2)
        }
        let manager = DisplayManager.shared
        manager.start()
        guard let device = manager.device(for: id) else {
            print("no display \(id)")
            exit(1)
        }
        // All refresh variants, not `resolutionChoices`: that list is deduped to
        // one row per size for the slider and would hide the faster rates.
        let candidates = device.usableModes.filter { $0.width == width && $0.height == height }
        // Prefer HiDPI, then the fastest refresh — the two things a user actually
        // cares about when asking for a specific size.
        guard let target = candidates.sorted(by: {
            if $0.isHiDPI != $1.isHiDPI { return $0.isHiDPI }
            return $0.refreshRate > $1.refreshRate
        }).first else {
            print("display \(id) does not offer \(width)x\(height). Available:")
            for mode in device.resolutionChoices { print("  \(mode.fullLabel)") }
            exit(1)
        }
        let ok = manager.applyRow(target, to: device)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        manager.refresh()
        print("set \(device.name) -> \(manager.device(for: id)?.currentMode?.fullLabel ?? "nil") applied=\(ok)")
    }
}


/// Compares the two ways to land a mode, on the path that actually persists.
///
/// `CGDisplaySetDisplayMode` is session-scoped: the change holds while the calling
/// process is alive and is rolled back when it exits. Only a
/// `CGCompleteDisplayConfiguration(..., .permanently)` transaction is written into
/// the user's saved display set. This prints both `CGError` codes so the choice in
/// `DisplayManager.apply` is evidence-backed rather than assumed.
@MainActor
enum PersistCheck {
    static func run(_ arguments: [String]) {
        guard arguments.count >= 3, let id = CGDirectDisplayID(arguments[1]) else {
            print("usage: --persist-check <displayID> <WIDTHxHEIGHT>")
            exit(2)
        }
        let parts = arguments[2].lowercased().split(separator: "x").map(String.init)
        guard parts.count == 2, let wantW = Int(parts[0]), let wantH = Int(parts[1]) else { exit(2) }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let pool = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode],
              let target = pool.first(where: { $0.width == wantW && $0.height == wantH }) else {
            print("mode not offered")
            exit(1)
        }

        print("before \(CGDisplayCopyDisplayMode(id).map { "\($0.width)x\($0.height)" } ?? "?")")

        // Pure transaction first, with nothing before it.
        var ref: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&ref)
        print("begin     \(begin.rawValue)")
        if let config = ref {
            let configured = CGConfigureDisplayWithDisplayMode(config, id, target, nil)
            let completed = CGCompleteDisplayConfiguration(config, .forSession)
            print("session   configure=\(configured.rawValue) complete=\(completed.rawValue)")
            print("now       \(CGDisplayCopyDisplayMode(id).map { "\($0.width)x\($0.height)" } ?? "?")")
        }

        var ref2: CGDisplayConfigRef?
        let begin2 = CGBeginDisplayConfiguration(&ref2)
        print("begin2    \(begin2.rawValue)")
        if let config = ref2 {
            let configured = CGConfigureDisplayWithDisplayMode(config, id, target, nil)
            let completed = CGCompleteDisplayConfiguration(config, .permanently)
            print("permanent configure=\(configured.rawValue) complete=\(completed.rawValue)")
            print("now       \(CGDisplayCopyDisplayMode(id).map { "\($0.width)x\($0.height)" } ?? "?")")
        }
    }
}

/// Geometry check for the "the panel must never leave the screen" invariant.
///
/// `--geometry-test` runs the panel's sizing and clamping against screen sizes
/// this machine does not have (the smallest macOS resolution, a 16:10 laptop, a
/// short ultrawide). Changing the real display to 800x600 to test this would be
/// both disruptive and non-deterministic, so the pure functions are exercised
/// directly and every case is reported.
@MainActor
enum GeometryTest {
    private struct Case {
        let name: String
        let visible: NSRect
    }

    static func run() {
        let cases: [Case] = [
            Case(name: "1920x1080 (menu bar + dock)", visible: NSRect(x: 0, y: 87, width: 1920, height: 969)),
            Case(name: "1440x900 scaled", visible: NSRect(x: 0, y: 75, width: 1440, height: 795)),
            Case(name: "1024x768 minimum-ish", visible: NSRect(x: 0, y: 60, width: 1024, height: 668)),
            Case(name: "800x600 smallest", visible: NSRect(x: 0, y: 55, width: 800, height: 505)),
            Case(name: "640x480 floor", visible: NSRect(x: 0, y: 44, width: 640, height: 396)),
            Case(name: "external 1600x900 above", visible: NSRect(x: -347, y: 900, width: 1600, height: 870)),
            Case(name: "short ultrawide", visible: NSRect(x: 0, y: 40, width: 3440, height: 550))
        ]

        var failures = 0

        func pad(_ text: String, _ width: Int) -> String {
            text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
        }

        print(pad("screen", 28) + pad("panel", 14) + pad("in-bounds", 11) + pad("fits", 7) + "result")
        print(String(repeating: "-", count: 72))

        for item in cases {
            let budget = AppMenuPanelController.budget(forVisible: item.visible)
            let panelSize = NSSize(width: budget.width, height: budget.height)

            // Same anchor the live code uses: centred under the status item.
            let desired = NSPoint(
                x: item.visible.midX - panelSize.width / 2,
                y: item.visible.maxY - 24 - panelSize.height - 4
            )
            let origin = AppMenuPanelController.clampedOrigin(
                panelSize: panelSize, desired: desired, visible: item.visible
            )
            let frame = NSRect(origin: origin, size: panelSize)

            // Half-point tolerance: the clamp works in whole points.
            let inside = item.visible.insetBy(dx: -0.5, dy: -0.5).contains(frame)
            let fits = panelSize.height <= item.visible.height && panelSize.width <= item.visible.width
            let ok = inside && fits
            if !ok { failures += 1 }

            let panel = String(format: "%.0fx%.0f", panelSize.width, panelSize.height)
            print(pad(item.name, 28)
                  + pad(panel, 14)
                  + pad(inside ? "ok" : "FAIL", 11)
                  + pad(fits ? "ok" : "FAIL", 7)
                  + (ok ? "pass" : "OUT OF BOUNDS"))
        }

        print("")
        print(failures == 0 ? "geometry: all \(cases.count) cases pass" : "geometry: \(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}

/// Live check: open the panel, shrink the menu-bar screen, confirm the panel
/// stayed on screen, then restore.
///
/// The geometry test covers the maths; this covers the wiring — that a real
/// reconfiguration actually triggers a relayout instead of leaving the panel at
/// coordinates from the old screen. The resolution is restored in every path,
/// including a failed assertion, because leaving a user's screen at 1024x768
/// would be a worse outcome than the test failing.
@MainActor
enum OverflowTest {
    static func run() {
        let manager = DisplayManager.shared
        manager.start()

        guard let device = manager.devices.first(where: \.isBuiltIn),
              let original = device.currentMode else {
            print("no built-in display")
            exit(1)
        }
        let small = device.usableModes.first {
            $0.width == 1024 && $0.height == 768 && !$0.isHiDPI
        } ?? device.usableModes.first { $0.width <= 1152 && !$0.isHiDPI }

        guard let small else {
            print("no small mode offered")
            exit(1)
        }

        let model = PanelModel()
        model.start()
        let controller = AppMenuPanelController(model: model)
        controller.show(relativeTo: nil)
        pump(0.5)

        print("geometry is \(screenUnion())")
        print("opened   \(report(controller))")

        let shrunk = manager.apply(small, to: device)
        pump(1.2)
        let duringOK = report(controller)
        print("shrunk   \(duringOK)  applied=\(shrunk)")

        // Restore first, assert afterwards: the assertion must not be able to
        // leave the screen modified.
        let restored = manager.apply(original, to: device)
        pump(1.2)
        let afterOK = report(controller)
        print("restored \(afterOK)  applied=\(restored) mode=\(manager.device(for: device.id)?.currentMode?.fullLabel ?? "nil")")

        let ok = duringOK.hasPrefix("inside") && afterOK.hasPrefix("inside") && restored
        print("")
        print(ok ? "overflow: pass — panel stayed on screen across a resolution change"
                 : "overflow: FAIL")
        exit(ok ? 0 : 1)
    }

    private static func pump(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func screenUnion() -> String {
        NSScreen.screens.map {
            "\(Int($0.visibleFrame.width))x\(Int($0.visibleFrame.height))"
        }.joined(separator: " + ")
    }

    private static func report(_ controller: AppMenuPanelController) -> String {
        guard let window = NSApp.windows.first(where: { $0.isVisible }),
              let screen = window.screen ?? NSScreen.main else {
            return "no panel"
        }
        let frame = window.frame
        let visible = screen.visibleFrame
        let inside = visible.insetBy(dx: -0.5, dy: -0.5).contains(frame)
        return (inside ? "inside   " : "OUTSIDE  ")
            + String(format: "panel=%.0fx%.0f at (%.0f,%.0f) visible=%.0fx%.0f",
                     frame.width, frame.height, frame.minX, frame.minY,
                     visible.width, visible.height)
    }
}

/// Proves the software-dimming fallback actually changes the output.
///
/// Reads the display's gamma transfer table, applies a level through
/// `BrightnessService`, reads again, then clears and reads a third time. A slider
/// that moves without changing the table would look identical in the UI, so the
/// check is on the table, not on the model. The display is restored before any
/// verdict is printed.
@MainActor
enum SoftwareDimmingTest {
    static func run(_ arguments: [String]) {
        let id: CGDirectDisplayID = arguments.count > 1 ? CGDirectDisplayID(arguments[1]) ?? 2 : 2
        let sampleCount = 256

        func readTable() -> [Float]? {
            var red = [Float](repeating: 0, count: sampleCount)
            var green = [Float](repeating: 0, count: sampleCount)
            var blue = [Float](repeating: 0, count: sampleCount)
            var actual: UInt32 = 0
            let error = CGGetDisplayTransferByTable(id, UInt32(sampleCount), &red, &green, &blue, &actual)
            guard error == .success, actual > 0 else { return nil }
            return red
        }

        guard let before = readTable() else {
            print("could not read transfer table for display \(id)")
            exit(1)
        }

        let service = BrightnessService.shared
        let device = DisplayDevice(id: id, name: "display \(id)", isBuiltIn: false, isMain: false, avUnit: nil)
        let applied = service.setSoftwareLevel(0.5, for: device)
        let during = readTable() ?? before
        service.clearSoftwareLevel(for: device)
        let after = readTable() ?? before

        func maxDelta(_ a: [Float], _ b: [Float]) -> Float {
            zip(a, b).map { abs($0 - $1) }.max() ?? 0
        }
        let changed = maxDelta(before, during)
        let restored = maxDelta(before, after)

        print("display \(id)")
        print(String(format: "  setLevel applied   %@", applied ? "yes" : "no"))
        print(String(format: "  table delta while dimmed  %.4f", changed))
        print(String(format: "  table delta after clear   %.4f", restored))

        let ok = applied && changed > 0.05 && restored < 0.01
        print("")
        print(ok ? "software dimming: pass" : "software dimming: FAIL")
        exit(ok ? 0 : 1)
    }
}

/// Proves a resolution drag commits once, not once per step.
///
/// Sweeps the slider across its whole range through the preview path, then
/// releases. Asserts zero mode changes during the sweep and exactly one after.
/// Without this, "dragging causes several black screens" is only observable by
/// eye — and on this machine each change blanks the display for a second or more.
@MainActor
enum DragTest {
    static func run() {
        let manager = DisplayManager.shared
        manager.start()

        // Prefer the external display: its mode changes are the slow ones.
        guard let device = manager.devices.first(where: { !$0.isBuiltIn }) ?? manager.devices.first,
              let original = device.currentMode else {
            print("no display")
            exit(1)
        }

        let model = PanelModel()
        model.start()

        var modeChanges = 0
        let token = NotificationCenter.default.addObserver(
            forName: .displayModeChanged, object: nil, queue: nil
        ) { _ in modeChanges += 1 }

        print("drag test: \(device.name) (id \(device.id))")
        print("  start        \(original.fullLabel)")

        let steps = 24
        for step in 0...steps {
            model.previewResolutionSlider(Double(step) / Double(steps), device)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let duringSweep = modeChanges
        print("  swept        \(steps + 1) positions, mode changes = \(duringSweep)")
        print("  preview      \(model.resolutionLabel(device))")

        // Release somewhere in the middle so the target is a mode the panel is
        // likely to accept; the point is the count, not which mode.
        model.previewResolutionSlider(0.5, device)
        let target = model.resolutionLabel(device)
        model.commitResolutionSlider(device)
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        let afterRelease = modeChanges
        print("  released     target=\(target) total mode changes = \(afterRelease)")

        let restored = manager.apply(original, to: device)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        manager.refresh()
        print("  restored     \(manager.device(for: device.id)?.currentMode?.fullLabel ?? "nil") applied=\(restored)")
        NotificationCenter.default.removeObserver(token)

        let ok = duringSweep == 0 && afterRelease == 1 && restored
        print("")
        print(ok ? "drag: pass — one mode change per drag"
                 : "drag: FAIL (during=\(duringSweep) after=\(afterRelease) restored=\(restored))")
        exit(ok ? 0 : 1)
    }
}

/// Tries every resolution row on a display and reports which variants apply.
///
/// The panel offers several modes per logical size (different refresh rates and
/// pixel variants) and CoreGraphics refuses some of them. If the row the UI keeps
/// happens to be a refused one, that resolution looks broken even though a working
/// variant of the same size exists. `--audit-modes` proves or disproves that.
@MainActor
enum ModeAudit {
    static func run(_ arguments: [String]) {
        let manager = DisplayManager.shared
        manager.start()
        let wanted: CGDirectDisplayID? = arguments.count > 1 ? CGDirectDisplayID(arguments[1]) : nil
        guard let device = wanted.flatMap({ manager.device(for: $0) }) ?? manager.devices.first(where: { !$0.isBuiltIn }) else {
            print("no display"); exit(1)
        }
        guard let original = device.currentMode else { exit(1) }

        // Group every raw mode by logical size + scale class.
        var rows: [String: [DisplayModeInfo]] = [:]
        for mode in device.modes {
            rows[mode.rowKey, default: []].append(mode)
        }
        let ordered = rows.keys.sorted { lhs, rhs in
            (rows[lhs]?.first?.width ?? 0) < (rows[rhs]?.first?.width ?? 0)
        }

        print("mode audit: \(device.name) (id \(device.id))")
        print("  current   \(original.fullLabel) @\(Int(original.refreshRate))Hz")
        print("  rows      \(ordered.count)")
        print("")
        print("  " + "row".padding(toLength: 22, withPad: " ", startingAt: 0)
              + "variants  result")

        var restoredCount = 0
        var deadRows: [String] = []
        for key in ordered {
            guard let variants = rows[key], let first = variants.first else { continue }
            var worked: String?
            for variant in variants {
                if manager.apply(variant, to: device) {
                    worked = "\(variant.fullLabel) @\(Int(variant.refreshRate))"
                    break
                }
            }
            if worked == nil {
                deadRows.append(key)
            } else if device.currentMode?.rowKey != original.rowKey {
                if manager.apply(original, to: device) { restoredCount += 1 }
            }
            let label = first.fullLabel
            print("  " + label.padding(toLength: 22, withPad: " ", startingAt: 0)
                  + String(variants.count).padding(toLength: 10, withPad: " ", startingAt: 0)
                  + (worked ?? "ALL REFUSED"))
        }

        // Always end on the mode we started from.
        _ = manager.apply(original, to: device)
        RunLoop.current.run(until: Date().addingTimeInterval(1.0))
        manager.refresh()

        print("")
        print("  restored  \(manager.device(for: device.id)?.currentMode?.fullLabel ?? "nil")")
        print("  dead rows \(deadRows.isEmpty ? "none" : deadRows.joined(separator: ", "))")
        exit(deadRows.isEmpty ? 0 : 2)
    }
}

/// Exercises the HiDPI toggle end to end.
///
/// The toggle used to look broken because it demanded an exact same-size 2x mode.
/// This prints the candidate order it will walk and which one actually landed, then
/// toggles back.
@MainActor
enum HiDPITest {
    static func run(_ arguments: [String]) {
        let manager = DisplayManager.shared
        manager.start()
        let wanted: CGDirectDisplayID? = arguments.count > 1 ? CGDirectDisplayID(arguments[1]) : nil
        guard let device = wanted.flatMap({ manager.device(for: $0) }) ?? manager.devices.first(where: { !$0.isBuiltIn }),
              let before = device.currentMode else { print("no display"); exit(1) }

        print("hidpi test: \(device.name)")
        print("  before      \(before.fullLabel) @\(Int(before.refreshRate))Hz pix=\(before.pixelWidth)")
        print("  candidates  \(manager.hiDPICandidates(of: device).prefix(4).map(\.fullLabel).joined(separator: " -> "))")

        let toggled = manager.toggleHiDPI(device)
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        manager.refresh()
        let after = manager.device(for: device.id)?.currentMode
        print("  toggled     \(after?.fullLabel ?? "nil") @\(Int(after?.refreshRate ?? 0))Hz pix=\(after?.pixelWidth ?? 0) ok=\(toggled)")

        let back = manager.toggleHiDPI(device) // device objects were replaced by refresh
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))
        manager.refresh()
        let restored = manager.device(for: device.id)?.currentMode
        print("  toggled back \(restored?.fullLabel ?? "nil") ok=\(back)")

        let candidates = manager.hiDPICandidates(of: device)
        if candidates.isEmpty {
            // No same-desktop-size 2x mode of the panel's own: flexible scaling has to
            // synthesise one. Verify that path instead of pretending nothing can be done.
            let scaling = FlexibleScaling.shared
            guard scaling.isAvailable else {
                print("")
                print(toggled == false ? "hidpi: pass — no HiDPI counterpart for this size (control disabled)"
                                       : "hidpi: FAIL — toggled without a candidate")
                exit(toggled == false ? 0 : 1)
            }
            let enabled = scaling.enable(for: device)
            manager.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let flexed = manager.device(for: device.id)?.currentMode
            let flipped = flexed.map { $0.isHiDPI != before.isHiDPI && $0.pixelWidth == before.width * 2 } ?? false
            let gone = scaling.disable(for: device)
            manager.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(1.0))
            let restoredMode = manager.device(for: device.id)?.currentMode
            let roundTrip = restoredMode.map { $0.isHiDPI == before.isHiDPI && $0.pixelWidth == before.pixelWidth } ?? false
            print("")
            print("hidpi: flexible — \(before.fullLabel) -> \(flexed?.fullLabel ?? "?") (pix \(flexed?.pixelWidth ?? 0)) -> \(restoredMode?.fullLabel ?? "?")")
            print(enabled && flipped && gone && roundTrip ? "hidpi: pass — synthesised and released cleanly"
                                                          : "hidpi: FAIL (enabled=\(enabled) flipped=\(flipped) released=\(gone) roundTrip=\(roundTrip))")
            exit(enabled && flipped && gone && roundTrip ? 0 : 1)
        }
        // Contract: the scale class flips, the landing mode is one of the offered
        // candidates, and toggling again returns to the starting scale class.
        let flipped = after.map { $0.isHiDPI != before.isHiDPI } ?? false
        let roundTrip = restored.map { $0.isHiDPI == before.isHiDPI } ?? false
        print("")
        print(toggled && flipped && roundTrip ? "hidpi: pass — \(before.fullLabel) -> \(after?.fullLabel ?? "?") -> \(restored?.fullLabel ?? "?")" : "hidpi: FAIL (toggled=\(toggled) flipped=\(flipped) roundTrip=\(roundTrip))")
        exit(toggled && flipped && roundTrip ? 0 : 1)
    }
}

/// Verifies that a mode change does not disturb the display arrangement.
///
/// Two properties matter, and they are different:
///
/// * **No horizontal drift.** The window server re-anchors a display on the axis
///   perpendicular to the edge it shares with a neighbour, but the other axis must
///   stay put. Losing that axis is what makes a layout look scrambled.
/// * **No cumulative drift.** Cycling through resolutions must return to exactly the
///   same positions, not creep a few points per change.
///
/// Vertical re-anchoring is expected and not a failure: a display that grows upward
/// from a shared edge has to move on that axis.
@MainActor
enum ArrangementTest {
    struct Layout: Equatable {
        struct Entry: Equatable {
            let id: CGDirectDisplayID
            let rect: CGRect
            let main: Bool
        }
        var entries: [Entry] = []

        static func capture() -> Layout {
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: max(1, Int(count)))
            CGGetActiveDisplayList(count, &ids, &count)
            var entries: [Entry] = []
            for id in ids.prefix(Int(count)) {
                entries.append(Entry(id: id, rect: CGDisplayBounds(id), main: CGDisplayIsMain(id) != 0))
            }
            entries.sort { $0.id < $1.id }
            return Layout(entries: entries)
        }

        var description: String {
            entries.map {
                String(format: "%@%u:(%.0f,%.0f %.0fx%.0f)", $0.main ? "*" : " ", $0.id,
                       $0.rect.origin.x, $0.rect.origin.y, $0.rect.width, $0.rect.height)
            }.joined(separator: "  ")
        }

        /// Compares two layouts ignoring the display that changed mode.
        func horizontalDrift(to other: Layout, ignoring changed: CGDirectDisplayID) -> [String] {
            var drift: [String] = []
            for entry in entries where entry.id != changed {
                guard let now = other.entries.first(where: { $0.id == entry.id }) else { continue }
                if now.rect.origin.x != entry.rect.origin.x || now.rect.size != entry.rect.size {
                    drift.append(String(format: "%u moved/changed: (%.0f,%.0f %.0fx%.0f) -> (%.0f,%.0f %.0fx%.0f)",
                                        entry.id, entry.rect.origin.x, entry.rect.origin.y,
                                        entry.rect.width, entry.rect.height,
                                        now.rect.origin.x, now.rect.origin.y, now.rect.width, now.rect.height))
                }
            }
            return drift
        }

        func x(of id: CGDirectDisplayID) -> CGFloat? {
            entries.first { $0.id == id }?.rect.origin.x
        }
    }

    static func run(_ arguments: [String]) {
        let manager = DisplayManager.shared
        manager.start()
        let wanted: CGDirectDisplayID? = arguments.count > 1 ? CGDirectDisplayID(arguments[1]) : nil
        guard let device = wanted.flatMap({ manager.device(for: $0) }) ?? manager.devices.first(where: { !$0.isBuiltIn }),
              let original = device.currentMode else { print("no display"); exit(1) }
        guard let small = device.usableModes.first(where: { $0.width == 1280 && $0.height == 720 })
                ?? device.usableModes.first(where: { $0.width < original.width }) else {
            print("no alternative mode"); exit(1)
        }

        print("arrangement test: \(device.name) (id \(device.id))")
        let start = Layout.capture()
        print("  start       \(start.description)")

        var problems: [String] = []
        var endpoints: [Layout] = []

        for cycle in 1...3 {
            _ = manager.applyRow(small, to: device)
            RunLoop.current.run(until: Date().addingTimeInterval(1.4))
            manager.refresh()
            let atSmall = Layout.capture()

            _ = manager.applyRow(original, to: device)
            RunLoop.current.run(until: Date().addingTimeInterval(1.4))
            manager.refresh()
            let atOriginal = Layout.capture()
            endpoints.append(atOriginal)

            print("  cycle \(cycle)     \(atSmall.description)")
            print("           \(atOriginal.description)")
            problems += atSmall.horizontalDrift(to: start, ignoring: device.id)
            problems += atOriginal.horizontalDrift(to: start, ignoring: device.id)
        }

        // Cumulative drift: every return to the original mode must land identically.
        if let first = endpoints.first {
            for (index, layout) in endpoints.enumerated().dropFirst() {
                if layout.entries.first(where: { $0.id == device.id })?.rect != first.entries.first(where: { $0.id == device.id })?.rect {
                    problems.append("cumulative drift at cycle \(index + 1): \(layout.description) != \(first.description)")
                }
            }
        }

        print("")
        if problems.isEmpty {
            print("arrangement: stable — no horizontal or cumulative drift across 3 cycles")
            exit(0)
        } else {
            print("arrangement: PROBLEMS")
            Set(problems).forEach { print("  \($0)") }
            exit(2)
        }
    }
}

/// `--move <displayID> <x> <y>` repositions a display.
///
/// The origin has to be written in the *same* transaction as a mode, otherwise the
/// window server accepts `CGConfigureDisplayOrigin` and then drops it. So the
/// current mode is re-applied alongside the move.
@MainActor
enum MoveDisplay {
    static func run(_ arguments: [String]) {
        guard arguments.count >= 4,
              let id = CGDirectDisplayID(arguments[1]),
              let x = Int32(arguments[2]), let y = Int32(arguments[3]) else {
            print("usage: --move <displayID> <x> <y>")
            exit(2)
        }
        guard let mode = CGDisplayCopyDisplayMode(id) else { print("no display \(id)"); exit(1) }

        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let config = cfg else { exit(1) }
        let m = CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        let o = CGConfigureDisplayOrigin(config, id, x, y)
        let done = CGCompleteDisplayConfiguration(config, .permanently)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))

        let bounds = CGDisplayBounds(id)
        print(String(format: "move display %u -> (%.0f,%.0f)  mode=%d origin=%d complete=%d",
                     id, bounds.origin.x, bounds.origin.y, m.rawValue, o.rawValue, done.rawValue))
    }
}

/// Shows, for every *desktop size* the panel offers, whether a HiDPI version exists.
///
/// Grouping has to be by desktop size, not by backing pixels. The two pairings mean
/// different things:
///
/// * same desktop size  — 1600x900 1x <-> 1600x900 2x: same layout, twice the pixels.
///   This is what "High Resolution (HiDPI)" means.
/// * same backing pixels — 1600x900 1x <-> 800x450 2x: same sharpness, half the layout.
///   This is a resolution change that happens to be expressed as a scale change.
///
/// Grouping by pixels hid the first kind entirely, which made it look like HiDPI was
/// unavailable.
@MainActor
enum HiDPIMatrix {
    static func run(_ arguments: [String]) {
        let manager = DisplayManager.shared
        manager.start()
        let wanted: CGDirectDisplayID? = arguments.count > 1 ? CGDirectDisplayID(arguments[1]) : nil
        guard let device = wanted.flatMap({ manager.device(for: $0) }) ?? manager.devices.first(where: { !$0.isBuiltIn }) else {
            print("no display"); exit(1)
        }
        guard let current = device.currentMode else { exit(1) }

        var bySize: [String: (lodpi: DisplayModeInfo?, hidpi: DisplayModeInfo?)] = [:]
        for mode in device.allSelectableModes where device.matchesNativeAspect(mode) {
            let key = "\(mode.width)x\(mode.height)"
            var entry = bySize[key] ?? (nil, nil)
            if mode.isHiDPI { if entry.hidpi == nil { entry.hidpi = mode } }
            else if entry.lodpi == nil { entry.lodpi = mode }
            bySize[key] = entry
        }

        print("hidpi matrix: \(device.name)  current \(current.fullLabel) pixel=\(current.pixelWidth)")
        print("")
        print("  " + "桌面尺寸".padding(toLength: 14, withPad: " ", startingAt: 0)
              + "1x 背板".padding(toLength: 12, withPad: " ", startingAt: 0)
              + "2x 背板".padding(toLength: 12, withPad: " ", startingAt: 0)
              + "可切 HiDPI")

        var both = 0
        let keys = bySize.keys.sorted { lhs, rhs in
            (bySize[lhs]?.lodpi?.width ?? 0) < (bySize[rhs]?.lodpi?.width ?? 0)
        }
        for key in keys {
            guard let e = bySize[key] else { continue }
            let can = e.lodpi != nil && e.hidpi != nil
            if can { both += 1 }
            print("  " + key.padding(toLength: 14, withPad: " ", startingAt: 0)
                  + (e.lodpi.map { "\($0.pixelWidth)" } ?? "—").padding(toLength: 12, withPad: " ", startingAt: 0)
                  + (e.hidpi.map { "\($0.pixelWidth)" } ?? "—").padding(toLength: 12, withPad: " ", startingAt: 0)
                  + (can ? "✓" : "—"))
        }
        print("")
        print("  \(both) / \(keys.count) 个桌面尺寸可切 HiDPI")

        // Prove one toggle end to end where a pair exists.
        if let sample = bySize.values.first(where: { $0.lodpi != nil && $0.hidpi != nil })?.lodpi {
            _ = manager.applyRow(sample, to: device)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            manager.refresh()
            guard let d = manager.device(for: device.id) else { exit(1) }
            let before = d.currentMode
            let ok = manager.toggleHiDPI(d)
            RunLoop.current.run(until: Date().addingTimeInterval(1.4))
            manager.refresh()
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
            manager.refresh()
            let after = manager.device(for: device.id)?.currentMode
            print("  实测  \(before?.fullLabel ?? "?") -> \(after?.fullLabel ?? "?") ok=\(ok)")
            _ = manager.applyRow(current, to: device)
            RunLoop.current.run(until: Date().addingTimeInterval(1.2))
            manager.refresh()
            print("  还原  \(manager.device(for: device.id)?.currentMode?.fullLabel ?? "?")")
            exit(ok ? 0 : 1)
        }
        exit(2)
    }
}
