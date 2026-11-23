import AppKit

/// Prints what the menu and the keyboard path will actually do, given the preferences.
///
/// These exist because the previous build's switches were decorative: the settings pane held
/// its own `@State`, so nothing outside the pane could observe them. A screenshot cannot tell
/// "the row is gone" from "the row scrolled off", and synthetic media-key events are dropped
/// unless the posting binary is itself accessibility-trusted — so the two things that used to
/// be untestable are printed here instead.
enum UIPrefsTest {
    static func runMenuRows() {
        DisplayManager.shared.start()
        print("menu rows as rendered (Preferences.menuRowEnabled)")
        print(String(repeating: "=", count: 56))
        let enabled = AppMenuSubmenu.allCases.filter { Preferences.menuRowEnabled($0) }
        let hidden = AppMenuSubmenu.allCases.filter { !Preferences.menuRowEnabled($0) }
        print("visible (\(enabled.count)): \(enabled.map(\.rawValue).joined(separator: ", "))")
        print("hidden  (\(hidden.count)): \(hidden.map(\.rawValue).joined(separator: ", "))")
        print("connect switch: \(Preferences.connectOptions ? "display connect" : "keyboard target")")
        print("detached listed: \(Preferences.showDetachedDisplays)")
        let detached = Preferences.detachedDisplays(live: Set(DisplayManager.shared.devices.map(\.id)))
        print("detached now: \(detached.map { "\($0.name)(\($0.id))" }.joined(separator: ", "))")
    }

    static func runKeyTest() {
        DisplayManager.shared.start()
        let manager = DisplayManager.shared
        print("media key path")
        print(String(repeating: "=", count: 56))
        print("nativeBrightnessKeys=\(Preferences.nativeBrightnessKeys) nativeVolumeKeys=\(Preferences.nativeVolumeKeys) osd=\(Preferences.osdEnabled)")

        // The tap path itself needs real key presses; what is testable here is the decision it
        // makes: which display, which backend, and whether the key would be consumed.
        let manager2 = PanelModel()
        manager2.start()
        guard let target = manager2.keyboardTarget else { print("no keyboard target"); return }
        print("keyboard target  \(target.name) (id \(target.id))")

        let consumedBrightness = Preferences.nativeBrightnessKeys && manager2.canControlBrightness(target)
        let consumedVolume = Preferences.nativeVolumeKeys && manager2.canControlVolume(target)
        print("consumes brightness keys: \(consumedBrightness)")
        print("consumes volume keys:     \(consumedVolume)")

        let before = manager2.volume(target)
        manager2.adjustVolumeBy(1.0 / 16.0)
        usleep(400_000)
        let after = manager2.volume(target)
        print(String(format: "volume step: %.0f%% -> %.0f%% (backend %@)", before * 100, after * 100, manager2.volumeCaption(for: target)))
        manager2.setVolume(before, target)
        print("restored to \(Int(before * 100))%")

        let brightnessBefore = manager2.brightness(target)
        manager2.adjustBrightnessBy(-1.0 / 16.0)
        usleep(300_000)
        print(String(format: "brightness step: %.0f%% -> %.0f%% (backend %@)", brightnessBefore * 100, manager2.brightness(target) * 100, manager2.brightnessCaption(for: target)))
        manager2.setBrightness(brightnessBefore, target)
        print("restored to \(Int(brightnessBefore * 100))%")
    }
}
