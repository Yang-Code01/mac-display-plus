import AppKit
import SwiftUI

/// Menu bar item, keyboard handling, and the wiring between them.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let model = PanelModel()
    private var panelController: AppMenuPanelController!
    private var mediaKeyTap: MediaKeyTap?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        panelController = AppMenuPanelController(model: model)
        panelController.onSettings = { [weak self] in self?.showSettings() }
        panelController.onQuit = { NSApp.terminate(nil) }

        setUpStatusItem()
        model.start()

        // Brightness and volume keys are handled through a CGEventTap rather than by
        // pretending to be the system, because intercepting the real media keys also lets
        // us keep working when the display has no native brightness.
        //
        // The tap is installed only for the key groups the user left enabled, and it is
        // reinstalled whenever those switches change: consuming a key the app will not act
        // on would be worse than not tapping at all.
        startMediaKeyTapIfNeeded()
        NotificationCenter.default.addObserver(
            forName: Preferences.changed, object: nil, queue: .main
        ) { [weak self] _ in self?.startMediaKeyTapIfNeeded() }

        // Debug hook: opens a PiP window and leaves it up, so it can be inspected.
        if ProcessInfo.processInfo.environment["DPP_PIP_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let device = self.model.devices.first else { return }
                self.model.togglePictureInPicture(device)
            }
        }

        // Debug hook: exercises the capture pipeline and reports what actually happened.
        if ProcessInfo.processInfo.environment["DPP_STREAM_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.runStreamTest()
            }
        }

        // Debug hook: runs the colour-profile write attempt inside a real GUI process.
        // The same call returns false from the CLI, which is what made "true only when the
        // system allows it" testable at all.
        if ProcessInfo.processInfo.environment["DPP_COLOR_TEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                ColourProfileTest.run()
                NSApp.terminate(nil)
            }
        }

        // Debug hook: opens the settings window on launch, so the window can be
        // captured and compared without a status item click.
        if ProcessInfo.processInfo.environment["DPP_SETTINGS_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.showSettings()
            }
        }

        // Debug hook: opens the panel shortly after launch so the real
        // status-item-anchored path can be exercised without a synthetic click.
        if ProcessInfo.processInfo.environment["DPP_OPEN_ON_LAUNCH"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self, let button = self.statusItem.button else { return }
                self.panelController.toggle(relativeTo: button)
            }
        }

        NotificationCenter.default.addObserver(
            forName: .displayModeChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.updateStatusIcon() }
        NotificationCenter.default.addObserver(
            forName: .displayTopologyChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.updateStatusIcon() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        mediaKeyTap?.stop()
        // Undo any software dimming so quitting never leaves a dimmed screen
        // behind. Restores every profile rather than only the displays this
        // session touched, because a missed one is unrecoverable without a logout.
        BrightnessService.shared.clearAllSoftwareLevels()
    }

    // MARK: - Status item

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.image = statusImage()
        button.image?.isTemplate = true
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    private func statusImage() -> NSImage? {
        NSImage(systemSymbolName: "display.2", accessibilityDescription: "display++")
            ?? NSImage(systemSymbolName: "display", accessibilityDescription: "display++")
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = statusImage()
        statusItem?.button?.image?.isTemplate = true
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showQuickMenu()
        } else {
            panelController.toggle(relativeTo: sender)
        }
    }

    /// Right-click opens a native menu of app-wide actions.
    private func showQuickMenu() {
        panelController.close()
        let menu = NSMenu()

        menu.addItem(withTitle: L("Redetect Displays"), action: #selector(redetect), keyEquivalent: "").target = self
        menu.addItem(.separator())

        if let target = model.keyboardTarget {
            let brightness = Int((model.brightness(target) * 100).rounded())
            let item = NSMenuItem(title: L("Brightness: %d%%", brightness), action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(withTitle: L("Settings…"), action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit display++"), action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach so left-click keeps opening the custom panel next time.
        statusItem.menu = nil
    }

    @objc private func redetect() { model.redetect() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - Media keys

    private func handleMediaKey(_ key: MediaKeyTap.Key) -> Bool {
        let step = 1.0 / 16.0
        switch key {
        case .brightnessUp, .brightnessDown:
            guard Preferences.nativeBrightnessKeys, let target = model.keyboardTarget else { return false }
            model.adjustBrightnessBy(key == .brightnessUp ? step : -step)
            showOSD(symbol: key == .brightnessUp ? "sun.max.fill" : "sun.min.fill",
                    title: target.name,
                    level: model.brightness(target),
                    on: target)
            return true

        case .volumeUp, .volumeDown:
            guard Preferences.nativeVolumeKeys, let target = model.keyboardTarget else { return false }
            model.adjustVolumeBy(key == .volumeUp ? step : -step)
            showOSD(symbol: model.isMuted(target) ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: target.name,
                    level: model.isMuted(target) ? 0 : model.volume(target),
                    on: target)
            return true

        case .mute:
            guard Preferences.nativeVolumeKeys, let target = model.keyboardTarget else { return false }
            model.toggleMute(target)
            showOSD(symbol: model.isMuted(target) ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    title: target.name,
                    level: model.isMuted(target) ? 0 : model.volume(target),
                    on: target)
            return true
        }
    }

    private func runStreamTest() {
        print("stream test")
        print(String(repeating: "=", count: 56))
        print("preflight permission: \(CGPreflightScreenCaptureAccess())")
        guard let device = model.devices.first else {
            print("no displays"); NSApp.terminate(nil); return
        }
        print("target: \(device.name) (id \(device.id))")
        StreamService.shared.startPiP(for: device.id, name: device.name) { result in
            switch result {
            case .success:
                print("capture started")
            case .failure(let failure):
                print("capture failed: \(failure.message)")
            }
        }
        // ScreenCaptureKit is change-driven: a static desktop produces no frames at all, so the
        // test has to move something. The cursor is part of the capture (`showsCursor`).
        var ticks = 0
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { t in
            ticks += 1
            let point = CGPoint(x: 400 + (ticks % 40) * 8, y: 300 + (ticks % 20) * 6)
            CGWarpMouseCursorPosition(point)
            if ticks > 30 { t.invalidate() }
        }
        _ = timer

        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            let frames = StreamService.shared.frameCount(for: device.id)
            print("frames after 4 s: \(frames)")
            print(frames > 0 ? "result: capture works" : "result: no frames (permission or content filter)")
            StreamService.shared.stopAll()
            NSApp.terminate(nil)
        }
    }

    private func startMediaKeyTapIfNeeded() {
        let wantsAnything = Preferences.nativeBrightnessKeys || Preferences.nativeVolumeKeys
        guard wantsAnything else {
            mediaKeyTap?.stop()
            mediaKeyTap = nil
            return
        }
        if mediaKeyTap == nil {
            mediaKeyTap = MediaKeyTap { [weak self] key in
                self?.handleMediaKey(key) ?? false
            }
        }
        mediaKeyTap?.start()
    }

    /// One OSD is shared by every adjustment; the switch in the Keyboard pane turns
    /// it on and off.
    private func showOSD(symbol: String, title: String, level: Double, on device: DisplayDevice) {
        guard Preferences.osdEnabled else { return }
        OSDController.shared.show(
            symbol: symbol,
            title: title,
            level: level,
            on: NSScreen.screens.first {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == device.id
            }
        )
    }

    // MARK: - Settings

    @objc private func showSettings() {
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        // 800 × 600, full-height sidebar, title bar drawn over it:
        // `.fullSizeContentView` plus a transparent title bar produces that shape
        // rather than a stock titled window.
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "display++"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 600)
        window.contentView = NSHostingView(rootView: SettingsRootView(model: model))
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
