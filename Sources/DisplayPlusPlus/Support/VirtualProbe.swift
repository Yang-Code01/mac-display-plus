import AppKit
import CoreGraphics
import Foundation

/// Exercises the private virtual-display initialiser end to end.
///
/// The reason this exists: `-[CGVirtualDisplay initWithDescriptor:]` fails with an
/// Objective-C exception, which cannot be caught from Swift, so any experiment with
/// it has to be a mode of the app that is only reached from the command line. The
/// probe reports what the window server actually did with the display — the point
/// of contention is whether a display that exists server side also shows up in the
/// CoreGraphics list every other process reads.
///
///   display++ --probe-virtual [width height] [--lohidpi]
@MainActor
enum VirtualProbe {
    static func run(_ arguments: [String]) {
        let numbers = arguments.dropFirst().compactMap { Int($0) }
        let width = numbers.first ?? 1920
        let height = numbers.count > 1 ? numbers[1] : 1080
        let hiDPI = !arguments.contains("--lohidpi")

        let service = VirtualScreenService.shared
        service.forceEnabled = true

        print("virtual screen probe")
        print("  classes        \(service.isAvailable ? "present" : "MISSING")")
        print("  request        \(width) × \(height) hiDPI=\(hiDPI)")

        let created = service.create(width: width, height: height, name: "display++ virtual", hiDPI: hiDPI)
        let id = service.lastCreatedID
        print("  created        \(created) id=\(id)")

        guard created, id != 0 else {
            print("  result         refused")
            exit(1)
        }

        // The display is registered in the display space (bounds and modes answer),
        // but the window server leaves it out of the online set. Enabling it through
        // a display configuration transaction is the public way to ask for that.
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        if let modes = CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode], !modes.isEmpty {
            print("  modes          \(modes.count), first=\(modes[0].width)×\(modes[0].height) pix=\(modes[0].pixelWidth)×\(modes[0].pixelHeight)")
            // Pick the HiDPI sibling if the display offers one, so the probe shows
            // the 2x case the feature actually needs.
            let wanted = modes.first { $0.width == width && $0.height == height && $0.pixelWidth == width * (hiDPI ? 2 : 1) }
            print("  mode list      " + modes.map { "\($0.width)x\($0.height)@\($0.pixelWidth)" }.joined(separator: " "))
            let target = wanted ?? modes.first { $0.pixelWidth > $0.width } ?? modes[0]
            typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
            let enable: EnableFn? = {
                guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
                      let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
                return unsafeBitCast(symbol, to: EnableFn.self)
            }()
            var config: CGDisplayConfigRef?
            let began = CGBeginDisplayConfiguration(&config)
            let enabled = enable?(config, id, true) ?? -1
            let moved = CGConfigureDisplayOrigin(config, id, 3040, 0)
            let configured = CGConfigureDisplayWithDisplayMode(config, id, target, nil)
            let done = CGCompleteDisplayConfiguration(config, .forSession)
            print("  configure      begin=\(began.rawValue) enable=\(enabled) origin=\(moved.rawValue) set=\(configured.rawValue) complete=\(done.rawValue) using=\(target.width)×\(target.height) pix=\(target.pixelWidth)")

            // Second pass: the mode is settled now, so ask the window server to enable
            // the display on its own, then toggle it once, which is the sequence a user
            // would produce from the Displays panel.
            if let enable {
                for attempt in 1...2 {
                    var second: CGDisplayConfigRef?
                    let began2 = CGBeginDisplayConfiguration(&second)
                    let off = enable(second, id, false)
                    let on = enable(second, id, true)
                    let done2 = CGCompleteDisplayConfiguration(second, .forSession)
                    print("  enable pass \(attempt) begin=\(began2.rawValue) off=\(off) on=\(on) complete=\(done2.rawValue)")
                    RunLoop.current.run(until: Date().addingTimeInterval(1.0))
                    print("               online=\(CGDisplayIsOnline(id)) active=\(CGDisplayIsActive(id)) listed=\(CGGetOnlineDisplayList(0, nil, nil))")
                }
            }
        } else {
            print("  modes          none — CoreGraphics has no modes for this display")
        }

        for step in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: 16)
            var listed: UInt32 = 16
            CGGetOnlineDisplayList(16, &ids, &listed)
            let names = ids.prefix(Int(listed)).map(String.init).joined(separator: ",")
            let modes = CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary)
            let modeCount = (modes as? [Any])?.count ?? 0
            print("  t=\((step + 1) * 500)ms  online=\(count)[\(names)]  this: online=\(CGDisplayIsOnline(id)) active=\(CGDisplayIsActive(id)) modes=\(modeCount) bounds=\(CGDisplayBounds(id))")
            if CGDisplayIsOnline(id) != 0 { break }
        }

        let screenSizes = NSScreen.screens.map { "\($0.frame.size)" }.joined(separator: " ")
        print("  NSScreen       \(NSScreen.screens.count) screens: \(screenSizes)")
        service.removeAll()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        var after: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &after)
        print("  after remove   online=\(after)")
    }
}
