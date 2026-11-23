import AppKit
import CoreGraphics
import Foundation

/// End-to-end checks for the controls that changed the system, so the README can cite
/// measured output instead of "should work".
///
/// Every step restores what it changed before moving on. The disconnect test in
/// particular re-enables the display before it prints, because a crash between the two
/// would leave a display off until the next login.
enum ControlTest {
    static func run(_ arguments: [String]) {
        print("display++ control test")
        print(String(repeating: "=", count: 56))

        volumeTest()
        mirrorTest()
        virtualScreenTest()
        if arguments.contains("--include-disconnect") {
            disconnectTest()
        } else {
            print("\ndisconnect   skipped (pass --include-disconnect to run it)")
        }

        print("\n" + String(repeating: "=", count: 56))
        print("done — every change was restored")
    }

    // MARK: - Volume

    private static func volumeTest() {
        print("\naudio devices")
        for device in AudioService.outputDevices() {
            let level = AudioService.level(of: device).map { String(format: "%.0f%%", $0 * 100) } ?? "no scalar"
            print("  \(device.name)  level=\(level)  mute=\(AudioService.isMuted(device))  channels=\(device.channels)")
        }

        guard let output = AudioService.defaultOutputDevice() else {
            print("  (no default output device)")
            return
        }
        let original = AudioService.level(of: output)
        let probe: Double = 0.37
        let wrote = AudioService.setLevel(probe, on: output)
        let readBack = AudioService.level(of: output)
        print("\nsoftware volume  wrote=\(wrote) target=\(Int(probe * 100))% read=\(readBack.map { Int($0 * 100) } ?? -1)%")
        if let original { _ = AudioService.setLevel(original, on: output) }
        print("                 restored to \(original.map { Int($0 * 100) } ?? -1)%")
    }

    // MARK: - Mirror

    private static func mirrorTest() {
        DisplayManager.shared.start()
        let displays = DisplayManager.shared.devices
        guard displays.count >= 2 else {
            print("\nmirror           skipped (needs two displays)")
            return
        }
        let master = displays.first { $0.isBuiltIn } ?? displays[0]
        let slave = displays.first { $0.id != master.id }
        guard let slave else { return }

        let startedAt = Date()
        let ok = DisplayControl.setMirror(slave, of: master)
        let reported = DisplayControl.mirrorMaster(of: slave)
        print("\nmirror           \(slave.name) -> \(master.name) ok=\(ok) master=\(reported ?? kCGNullDirectDisplay) (\(Int(Date().timeIntervalSince(startedAt) * 1000)) ms)")

        _ = DisplayControl.setMirror(slave, of: nil)
        let cleared = DisplayControl.mirrorMaster(of: slave)
        print("                 cleared=\(cleared == nil ? "yes" : "no")")
    }

    // MARK: - Virtual screen

    private static func virtualScreenTest() {
        print("\nvirtual screen   classes=\(VirtualScreenService.shared.isAvailable ? "available" : "missing") canCreate=\(VirtualScreenService.shared.canCreate)")
        guard VirtualScreenService.shared.canCreate else {
            print("                 skipped — see VirtualScreenService.canCreate for what the initialiser rejects")
            return
        }

        func online() -> Int {
            var count: UInt32 = 0
            CGGetOnlineDisplayList(0, nil, &count)
            return Int(count)
        }

        let before = online()
        let created = VirtualScreenService.shared.create(width: 1920, height: 1080, name: "display++ probe")
        // The window server publishes a virtual display asynchronously; 600 ms is enough
        // on this machine (measured offline with --probe-virtual).
        usleep(600_000)
        let during = online()
        print("                 created=\(created) online \(before) -> \(during)")
        VirtualScreenService.shared.removeAll()
        usleep(400_000)
        print("                 released, online=\(online())")
    }

    // MARK: - Disconnect

    private static func disconnectTest() {
        let displays = DisplayManager.shared.devices
        guard let external = displays.first(where: { !$0.isBuiltIn }) else {
            print("\ndisconnect       skipped (no external display)")
            return
        }
        print("\ndisconnect       canDisconnect=\(DisplayControl.canDisconnect)")
        let wasOnline = CGDisplayIsOnline(external.id) != 0
        let disabled = DisplayControl.setEnabled(external, false)
        let offline = CGDisplayIsOnline(external.id) == 0
        let enabled = DisplayControl.setEnabled(external, true)
        let backOnline = CGDisplayIsOnline(external.id) != 0
        print("                 \(external.name) offline=\(disabled && offline) (was online=\(wasOnline)) reconnected=\(enabled && backOnline)")
    }
}
