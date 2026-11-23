import AppKit
import Combine
import SwiftUI

/// Panel state and intents. Views stay dumb; every mutation goes through here so
/// there is one place that decides whether a change is applied to the hardware,
/// cached, or ignored.
final class PanelModel: ObservableObject {
    @Published private(set) var devices: [DisplayDevice] = []
    @Published private(set) var brightnessValues: [CGDirectDisplayID: Double] = [:]
    /// Volume per display, cached because the two backends read back differently:
    /// DDC answers with its own 0...max scale, a CoreAudio device with a scalar.
    @Published private(set) var volumeValues: [CGDirectDisplayID: Double] = [:]
    /// Which backend the volume row is actually driving, so the caption can say so.
    @Published private(set) var volumePaths: [CGDirectDisplayID: VolumePath] = [:]
    @Published private(set) var muteValues: [CGDirectDisplayID: Bool] = [:]
    /// Last known input source per display (VCP 0x60), `nil` until the panel answers.
    @Published private(set) var inputSources: [CGDirectDisplayID: UInt16] = [:]
    /// One-line result of the last control attempt, shown under the row it came from.
    @Published private(set) var controlNotice: [CGDirectDisplayID: String] = [:]
    /// Displays the brightness keys should drive. Persisted by CGDisplayID; if
    /// the id changes after a re-dock the display simply falls back to default.
    @Published private(set) var keyboardTargets: Set<CGDirectDisplayID> = []
    /// Where the resolution slider currently sits while the user is still dragging.
    /// Nothing is applied until the drag ends.
    @Published private(set) var resolutionPreview: [CGDirectDisplayID: DisplayModeInfo] = [:]
    /// Displays in the middle of a mode change, used to explain the black screen.
    @Published private(set) var switchingDisplays: Set<CGDirectDisplayID> = []
    /// Set when the display refused every variant of a resolution row, so the UI
    /// can say "not supported" instead of looking like nothing happened.
    @Published private(set) var unsupportedNotice: [CGDirectDisplayID: String] = [:]

    private let manager = DisplayManager.shared
    private let ddc = DDCService.shared
    private let brightnessService = BrightnessService.shared

    /// DDC writes are ~50 ms each. Coalescing slider drags keeps the panel
    /// responsive and stops the monitor's MCU from queueing stale values.
    private var ddcWork: [CGDirectDisplayID: DispatchWorkItem] = [:]
    private var observers: [NSObjectProtocol] = []

    init() {
        observers.append(NotificationCenter.default.addObserver(
            forName: .displayTopologyChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.syncFromManager(initial: false)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .displayModeChanged, object: nil, queue: .main
        ) { [weak self] notification in
            // The switch landed: drop the indicator and the preview.
            guard let self else { return }
            if let device = notification.object as? DisplayDevice {
                self.switchingDisplays.remove(device.id)
                self.resolutionPreview.removeValue(forKey: device.id)
            }
            self.objectWillChange.send()
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Sync

    func start() {
        // Registers the reconfiguration callback and does the first enumeration;
        // without this the manager holds no devices and the panel renders empty.
        manager.start()
        syncFromManager(initial: true)
        for device in devices where !device.isBuiltIn {
            ddc.probe(device) { [weak self] available in
                guard available else { return }
                self?.ddc.readBrightness(device) { [weak self] value in
                    guard let value else { return }
                    self?.brightnessValues[device.id] = value
                    device.brightness = value
                    self?.objectWillChange.send()
                }
            }
        }
    }

    func syncFromManager(initial: Bool) {
        devices = manager.devices
        if initial {
            // Arm everything. The keys are consumed by the event tap, so any
            // display left out would lose brightness control entirely.
            keyboardTargets = Set(devices.map(\.id))
        } else {
            // Keep targets that still exist, and adopt newly added displays.
            let live = Set(devices.map(\.id))
            keyboardTargets.formIntersection(live)
            if keyboardTargets.isEmpty {
                keyboardTargets = live
            }
        }
        for device in devices {
            if let cached = brightnessValues[device.id] {
                device.brightness = cached
                continue
            }
            switch brightnessPath(for: device) {
            case .native, .ddc:
                if let value = brightnessService.nativeLevel(of: device) {
                    brightnessValues[device.id] = value
                    device.brightness = value
                } else {
                    // DDC readings arrive asynchronously from the probe; until
                    // then show undimmed rather than an invented mid value.
                    brightnessValues[device.id] = device.brightness ?? 1
                }
            case .software:
                // Start undimmed. Engaging software dimming at launch would
                // degrade the image before the user asked for anything.
                let value = brightnessService.softwareLevel(of: device) ?? 1
                brightnessValues[device.id] = value
                device.brightness = value
            }
        }
        objectWillChange.send()
    }

    func redetect() {
        // DDC capability is a property of the cable and the port, both of which
        // can change between dockings, so a redetect re-probes from scratch.
        for device in devices { device.ddcAvailable = false }
        manager.redetectDisplays()
        syncFromManager(initial: false)
    }

    // MARK: - Brightness

    /// Which control a display's brightness slider is actually driving.
    ///
    /// Ordered by quality: hardware backlight through the system, then hardware
    /// backlight over DDC, then computer-side dimming. The UI shows which one is in
    /// use, because the three look different on screen.
    enum BrightnessPath {
        /// `DisplayServices` — the system's own backlight control.
        case native
        /// DDC/CI over I²C — the monitor's own backlight.
        case ddc
        /// Gamma transfer table — the signal is scaled, the backlight is not.
        case software
    }

    func brightnessPath(for device: DisplayDevice) -> BrightnessPath {
        if device.isBuiltIn {
            return brightnessService.canControlNatively(device) ? .native : .software
        }
        if device.ddcAvailable { return .ddc }
        return .software
    }

    func brightness(_ device: DisplayDevice) -> Double {
        brightnessValues[device.id] ?? device.brightness ?? 1
    }

    /// Value shown on the right of the caption. Just the percentage: the caption
    /// already names the mechanism, so repeating it here is noise.
    func brightnessLabel(_ device: DisplayDevice) -> String {
        "\(Int((brightness(device) * 100).rounded()))%"
    }

    /// Always true now: software dimming works on any display, so the slider is
    /// never a dead control. What changes is the path, which the caption states.
    func canControlBrightness(_ device: DisplayDevice) -> Bool { true }

    /// Caption above the slider. Names the mechanism rather than just "Brightness",
    /// because hardware and computer-side dimming are visibly different.
    func brightnessCaption(for device: DisplayDevice) -> String {
        switch brightnessPath(for: device) {
        case .native: return L("Brightness")
        case .ddc: return L("Brightness (DDC)")
        case .software: return L("Brightness (Software)")
        }
    }

    /// Shown under the slider when the panel backlight is out of reach.
    var softwareDimmingNote: String {
        L("Computer-side dimming — the display backlight is unchanged, so dark areas lose detail.")
    }

    /// One sentence naming the brightness backend in use, for the Device Control page.
    func brightnessExplanation(for device: DisplayDevice) -> String {
        switch brightnessPath(for: device) {
        case .native:
            return L("Brightness uses the system's own panel control (DisplayServices).")
        case .ddc:
            return L("Brightness uses DDC/CI on the display's I2C bus (VCP 0x10).")
        case .software:
            return L("Brightness falls back to a gamma-table dim: the backlight stays where it is and dark detail is lost.")
        }
    }

    /// Same, for volume.
    func volumeExplanation(for device: DisplayDevice) -> String {
        switch volumePath(for: device) {
        case .hardwareDDC:
            return L("Volume uses the display's own speaker control (VCP 0x62).")
        case .audioDevice(let name):
            return L("Volume drives the audio device “%@”.", name)
        case .none:
            return L("No volume backend is available for this display.")
        }
    }

    func setBrightness(_ value: Double, _ device: DisplayDevice) {
        let clamped = min(max(value, 0), 1)
        brightnessValues[device.id] = clamped
        device.brightness = clamped
        objectWillChange.send()

        switch brightnessPath(for: device) {
        case .native:
            _ = brightnessService.setNativeLevel(clamped, for: device)

        case .ddc:
            ddcWork[device.id]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.ddc.setBrightness(clamped, for: device) { ok in
                    guard !ok else { return }
                    // The link stopped answering: drop to software so the slider
                    // keeps doing something instead of going dead.
                    device.ddcAvailable = false
                    self.objectWillChange.send()
                    _ = self.brightnessService.setSoftwareLevel(clamped, for: device)
                }
            }
            ddcWork[device.id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)

        case .software:
            _ = brightnessService.setSoftwareLevel(clamped, for: device)
        }
    }

    func probeDDC(_ device: DisplayDevice) {
        guard !device.isBuiltIn else { return }
        device.ddcPending = true
        objectWillChange.send()
        ddc.probe(device) { [weak self] available in
            guard let self else { return }
            device.ddcPending = false
            device.ddcAvailable = available
            if available {
                // Hand the display back to its own backlight and undo any
                // computer-side dimming left over from the fallback.
                self.brightnessService.clearSoftwareLevel(for: device)
                self.ddc.readBrightness(device) { value in
                    if let value {
                        self.brightnessValues[device.id] = value
                        device.brightness = value
                    }
                    self.objectWillChange.send()
                }
            } else {
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - Resolution

    // MARK: - Resolution slider

    private func snappedMode(for value: Double, on device: DisplayDevice) -> DisplayModeInfo? {
        let choices = device.sliderChoices
        guard !choices.isEmpty else { return nil }
        let index = Int((value * Double(choices.count - 1)).rounded())
        return choices[min(max(index, 0), choices.count - 1)]
    }

    /// Slider position. While a drag is in progress this follows the preview, so
    /// the knob never fights the still-unchanged display.
    func resolutionSliderValue(_ device: DisplayDevice) -> Double {
        let choices = device.sliderChoices
        guard !choices.isEmpty, let target = resolutionPreview[device.id] ?? device.currentMode,
              let index = choices.firstIndex(where: {
                  $0.width == target.width && $0.height == target.height && $0.isHiDPI == target.isHiDPI
              }) else { return device.resolutionSliderValue }
        return Double(index) / Double(max(1, choices.count - 1))
    }

    /// Label above the slider, reflecting the preview so the user can read the
    /// target size before committing to a change.
    ///
    /// Only the *size* is shown here (`1600 × 900`). The
    /// scale class belongs to the HiDPI switch: printing `· 2x` here made that switch
    /// look like a resolution change, because the row changed when sharpness did.
    func resolutionLabel(_ device: DisplayDevice) -> String {
        (resolutionPreview[device.id] ?? device.currentMode)?.sizeLabel ?? "—"
    }

    func isSwitchingResolution(_ device: DisplayDevice) -> Bool {
        switchingDisplays.contains(device.id)
    }

    /// Called continuously while dragging: records intent only.
    ///
    /// A display mode change blanks the panel while it resyncs — and through a
    /// DP→HDMI converter it also re-handshakes. Applying on every slider step made
    /// one drag produce several black screens, so the change is deferred to release
    /// and the user gets exactly one.
    func previewResolutionSlider(_ value: Double, _ device: DisplayDevice) {
        guard let mode = snappedMode(for: value, on: device) else { return }
        resolutionPreview[device.id] = mode
        objectWillChange.send()
    }

    /// Called once when the drag ends: this is the only place a drag can change mode.
    func commitResolutionSlider(_ device: DisplayDevice) {
        guard let mode = resolutionPreview.removeValue(forKey: device.id) else { return }

        if let current = device.currentMode,
           current.width == mode.width, current.height == mode.height, current.isHiDPI == mode.isHiDPI {
            // Same row: nothing to apply, and no blank screen for nothing.
            objectWillChange.send()
            return
        }

        switchingDisplays.insert(device.id)
        unsupportedNotice.removeValue(forKey: device.id)
        objectWillChange.send()

        if FlexibleScaling.shared.isActive(for: device.id) {
            FlexibleScaling.shared.disable(for: device)
            manager.refresh()
        }

        let landed = manager.applyRow(mode, to: device)
        if !landed {
            // Every variant of this row was refused: drop it from the list and say
            // so. Silence is what made this look like a broken control.
            device.refusedModes.insert(mode.rowKey)
            unsupportedNotice[device.id] = L("This display does not accept that resolution.")
        }

        // Clear the indicator even if no notification arrives (a failed switch
        // posts nothing), so the panel can never get stuck saying "switching".
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.switchingDisplays.remove(device.id) != nil else { return }
            self.objectWillChange.send()
        }
    }

    func unsupportedNoticeText(_ device: DisplayDevice) -> String? {
        unsupportedNotice[device.id]
    }

    /// Whether the HiDPI control can do anything for this display.
    ///
    /// Two ways to be useful: the panel offers a same-size 2x twin of its own, or
    /// flexible scaling can synthesise one (a virtual display the panel mirrors while
    /// the window server composes the mode). The second is what makes this control work
    /// at sizes the panel cannot run natively, instead of only at the two it supports.
    func canToggleHiDPI(_ device: DisplayDevice) -> Bool {
        !manager.hiDPICandidates(of: device).isEmpty || FlexibleScaling.shared.isAvailable
    }

    func isFlexibleHiDPI(_ device: DisplayDevice) -> Bool {
        FlexibleScaling.shared.isActive(for: device.id)
    }

    /// Right-hand value for the HiDPI row.
    ///
    /// A disabled row with no explanation is what reads as "the control is broken".
    /// The row now states either what it will switch to or that this panel cannot do
    /// 2x at the size it is running.
    func hiDPIHint(_ device: DisplayDevice) -> String? {
        guard canToggleHiDPI(device) else { return L("No 2x twin") }
        // The switch changes sharpness at the same desktop size; it is not a resolution
        // change, and the row should not read like one.
        return device.isHiDPIActive ? L("On") : L("Sharper (2x)")
    }

    /// Desktop sizes on this panel that do have a 2x twin, ascending.
    ///
    /// Only the sizes where both scale classes exist count: those are the rows a user
    /// can actually reach from the resolution slider to get true HiDPI on a panel
    /// whose native pixels stop short of twice the size they want.
    func hiDPICapableSizes(_ device: DisplayDevice) -> [String] {
        let modes = device.usableModes
        var seen = Set<String>()
        var sizes: [(Int, String)] = []
        for mode in modes where !mode.isHiDPI {
            let hasTwin = modes.contains {
                $0.isHiDPI && $0.width == mode.width && $0.height == mode.height
            }
            guard hasTwin, seen.insert(mode.sizeLabel).inserted else { continue }
            sizes.append((mode.width, mode.sizeLabel))
        }
        return sizes.sorted { $0.0 < $1.0 }.map(\.1)
    }

    func apply(_ mode: DisplayModeInfo, to device: DisplayDevice) {
        if let current = device.currentMode, current.rowKey == mode.rowKey { return }
        // A flexible 2x mode is held alive by a virtual display of one specific size;
        // any other switch has to drop it first or it would keep the wrong mode alive.
        if FlexibleScaling.shared.isActive(for: device.id) {
            FlexibleScaling.shared.disable(for: device)
            manager.refresh()
        }
        switchingDisplays.insert(device.id)
        unsupportedNotice.removeValue(forKey: device.id)
        objectWillChange.send()
        if !manager.applyRow(mode, to: device) {
            device.refusedModes.insert(mode.rowKey)
            unsupportedNotice[device.id] = L("This display does not accept that resolution.")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            guard let self, self.switchingDisplays.remove(device.id) != nil else { return }
            self.objectWillChange.send()
        }
    }

    func setRefreshRate(_ rate: Double, for device: DisplayDevice) {
        _ = manager.setRefreshRate(rate, for: device)
        objectWillChange.send()
    }

    /// Why the HiDPI control is off, in words, naming the sizes this panel can do it at.
    func hiDPIUnavailableText(_ device: DisplayDevice) -> String {
        let sizes = hiDPICapableSizes(device)
        guard !sizes.isEmpty else { return L("This panel offers no HiDPI mode at any size.") }
        let current = device.currentMode?.sizeLabel ?? "—"
        return L("No 2x twin at %@. This panel can switch at %@.", current, sizes.suffix(3).joined(separator: ", "))
    }

    func toggleHiDPI(_ device: DisplayDevice) {
        unsupportedNotice.removeValue(forKey: device.id)

        // A mode the panel offers by itself is always the better switch: no mirror, no
        // blank frame, nothing to hold alive.
        if manager.toggleHiDPI(device) {
            objectWillChange.send()
            return
        }

        // Otherwise synthesise it. Turning it on blanks the panel for a couple of
        // seconds while it is mirrored onto the virtual display; turning it off drops
        // back to the panel's own mode and releases the virtual display.
        switchingDisplays.insert(device.id)
        objectWillChange.send()
        let scaling = FlexibleScaling.shared
        let ok: Bool
        if scaling.isActive(for: device.id) {
            ok = scaling.disable(for: device)
        } else if device.isHiDPIActive {
            // Already 2x through some other route; go back to the plain mode.
            ok = manager.toggleHiDPI(device)
        } else {
            ok = scaling.enable(for: device)
        }
        if !ok {
            unsupportedNotice[device.id] = L("This display does not accept that resolution.")
        }
        manager.refresh()
        syncFromManager(initial: false)
        switchingDisplays.remove(device.id)
        objectWillChange.send()
    }

    func setMain(_ device: DisplayDevice) {
        manager.setMain(device)
        manager.refresh()
        syncFromManager(initial: false)
    }

    func stepResolution(_ device: DisplayDevice, by offset: Int) {
        manager.stepResolution(device, by: offset)
        objectWillChange.send()
    }

    // MARK: - Keyboard targets

    func isKeyboardTarget(_ device: DisplayDevice) -> Bool {
        keyboardTargets.contains(device.id)
    }

    func setKeyboardTarget(_ device: DisplayDevice, _ isOn: Bool) {
        if isOn {
            keyboardTargets.insert(device.id)
        } else {
            keyboardTargets.remove(device.id)
        }
        objectWillChange.send()
    }

    /// Display the brightness keys should move: the main one if several are
    /// armed, so the keys keep doing something predictable.
    var keyboardTarget: DisplayDevice? {
        let armed = devices.filter { keyboardTargets.contains($0.id) }
        return armed.first(where: \.isMain) ?? armed.first
    }

    /// Step the volume of every armed display, same rule as brightness: the keys move all
    /// targets unless a group is synchronised.
    func adjustVolumeBy(_ delta: Double) {
        for device in devices where keyboardTargets.contains(device.id) && canControlVolume(device) {
            setVolume(volume(device) + delta, device)
        }
    }

    /// Step every armed display together: the keys move all targets, not just one.
    func adjustBrightnessBy(_ delta: Double) {
        for device in devices where keyboardTargets.contains(device.id) && canControlBrightness(device) {
            setBrightness(brightness(device) + delta, device)
        }
    }

    // MARK: - Volume

    /// Which backend the volume row drives. Three routes are possible (hardware DDC,
    /// the display's audio device, a software mixer) and the caption names the one in
    /// use; switching between them silently is how a volume slider ends up looking
    /// broken.
    enum VolumePath {
        case hardwareDDC
        case audioDevice(String)
        case none

        var labelKey: String {
            switch self {
            case .hardwareDDC: return "Volume (Hardware)"
            case .audioDevice: return "Volume (Audio Device)"
            case .none: return "Volume"
            }
        }
    }

    func volumePath(for device: DisplayDevice) -> VolumePath {
        if device.ddcAvailable { return .hardwareDDC }
        if let audio = AudioService.audioDevice(for: device.name, isBuiltIn: device.isBuiltIn) {
            return .audioDevice(audio.name)
        }
        return .none
    }

    func volumeCaption(for device: DisplayDevice) -> String {
        switch volumePaths[device.id] ?? volumePath(for: device) {
        case .hardwareDDC: return L("Volume (Hardware)")
        case .audioDevice(let name): return L("Volume (%@)", name)
        case .none: return L("Volume (Unavailable)")
        }
    }

    func volume(_ device: DisplayDevice) -> Double { volumeValues[device.id] ?? 0.75 }

    func volumeLabel(_ device: DisplayDevice) -> String { "\(Int((volume(device) * 100).rounded()))%" }

    func canControlVolume(_ device: DisplayDevice) -> Bool {
        if case .none = volumePath(for: device) { return false }
        return true
    }

    func isMuted(_ device: DisplayDevice) -> Bool { muteValues[device.id] ?? false }

    func setVolume(_ value: Double, _ device: DisplayDevice) {
        let clamped = min(max(value, 0), 1)
        volumeValues[device.id] = clamped
        objectWillChange.send()

        switch volumePath(for: device) {
        case .hardwareDDC:
            ddc.setVolume(clamped, of: device) { [weak self] ok in
                guard let self, !ok else { return }
                // The bus stopped answering; fall back rather than leave the slider
                // moving a number that goes nowhere.
                device.ddcAvailable = false
                self.objectWillChange.send()
                self.setVolume(clamped, device)
            }
        case .audioDevice:
            guard let audio = AudioService.audioDevice(for: device.name, isBuiltIn: device.isBuiltIn) else { return }
            _ = AudioService.setLevel(clamped, on: audio)
        case .none:
            break
        }
    }

    func toggleMute(_ device: DisplayDevice) {
        let next = !isMuted(device)
        muteValues[device.id] = next
        objectWillChange.send()
        switch volumePath(for: device) {
        case .hardwareDDC:
            ddc.setMuted(next, of: device) { _ in }
        case .audioDevice:
            guard let audio = AudioService.audioDevice(for: device.name, isBuiltIn: device.isBuiltIn) else { return }
            _ = AudioService.setMuted(next, on: audio)
        case .none:
            break
        }
    }

    /// Audio levels live outside the display layer, so they are polled once when the
    /// panel opens instead of on every topology change.
    func refreshVolume() {
        for device in devices {
            let path = volumePath(for: device)
            volumePaths[device.id] = path
            switch path {
            case .hardwareDDC:
                ddc.read(DDCService.VCP.volume, of: device) { [weak self] reading in
                    guard let self, let reading, reading.max > 0 else { return }
                    self.volumeValues[device.id] = Double(reading.current) / Double(reading.max)
                    self.objectWillChange.send()
                }
            case .audioDevice:
                guard let audio = AudioService.audioDevice(for: device.name, isBuiltIn: device.isBuiltIn) else { continue }
                if let level = AudioService.level(of: audio) { volumeValues[device.id] = level }
                muteValues[device.id] = AudioService.isMuted(audio)
            case .none:
                break
            }
        }
        objectWillChange.send()
    }

    // MARK: - Topology intents

    func setMirror(_ device: DisplayDevice, of master: DisplayDevice?) {
        if !DisplayControl.setMirror(device, of: master) {
            controlNotice[device.id] = L("The window server refused the mirror change.")
        } else {
            controlNotice.removeValue(forKey: device.id)
        }
        manager.refresh()
        syncFromManager(initial: false)
        objectWillChange.send()
    }

    func mirrorMaster(of device: DisplayDevice) -> DisplayDevice? {
        guard let id = DisplayControl.mirrorMaster(of: device) else { return nil }
        return devices.first { $0.id == id }
    }

    func isMain(_ device: DisplayDevice) -> Bool { CGDisplayIsMain(device.id) != 0 }

    func setMainDisplay(_ device: DisplayDevice) {
        _ = DisplayControl.setMain(device)
        manager.refresh()
        syncFromManager(initial: false)
    }

    func canDisconnect(_ device: DisplayDevice) -> Bool { !device.isBuiltIn && DisplayControl.canDisconnect }

    func setEnabled(_ device: DisplayDevice, _ enabled: Bool) {
        guard DisplayControl.setEnabled(device, enabled) else {
            controlNotice[device.id] = L("The window server refused the connection change.")
            objectWillChange.send()
            return
        }
        manager.redetectDisplays()
        syncFromManager(initial: false)
        objectWillChange.send()
    }

    func isEnabled(_ device: DisplayDevice) -> Bool { CGDisplayIsOnline(device.id) != 0 }

    func rotationLabel(_ device: DisplayDevice) -> String {
        "\(DisplayControl.rotationDegrees(of: device.id))°"
    }

    var canRotate: Bool { DisplayControl.canRotate }

    // MARK: - Input source

    func inputSource(_ device: DisplayDevice) -> DDCService.InputSource? {
        guard let raw = inputSources[device.id] else { return nil }
        return DDCService.InputSource(rawValue: raw)
    }

    func refreshInputSource(_ device: DisplayDevice) {
        guard !device.isBuiltIn else { return }
        ddc.read(DDCService.VCP.inputSource, of: device) { [weak self] reading in
            guard let self, let reading else { return }
            self.inputSources[device.id] = reading.current
            self.objectWillChange.send()
        }
    }

    func selectInputSource(_ source: DDCService.InputSource, for device: DisplayDevice) {
        ddc.select(input: source, of: device) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.inputSources[device.id] = source.rawValue
                self.controlNotice.removeValue(forKey: device.id)
            } else {
                self.controlNotice[device.id] = L("This display did not acknowledge the input source change.")
            }
            self.objectWillChange.send()
        }
    }

    func notice(_ device: DisplayDevice) -> String? { controlNotice[device.id] }

    // MARK: - Streaming / picture in picture

    @Published private(set) var streamingDisplays: Set<CGDirectDisplayID> = []

    func isStreaming(_ device: DisplayDevice) -> Bool { streamingDisplays.contains(device.id) }

    /// Starts or stops a PiP window for this display. Failures are reported on the row that
    /// was tapped, not swallowed: without Screen Recording permission the call cannot work at
    /// all, and "nothing happened" would read as a broken app.
    func togglePictureInPicture(_ device: DisplayDevice) {
        if isStreaming(device) {
            StreamService.shared.stop(device.id)
            streamingDisplays.remove(device.id)
            controlNotice.removeValue(forKey: device.id)
            objectWillChange.send()
            return
        }
        StreamService.shared.startPiP(for: device.id, name: device.name) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.streamingDisplays.insert(device.id)
                self.controlNotice.removeValue(forKey: device.id)
            case .failure(let failure):
                self.controlNotice[device.id] = failure.message
            }
            self.objectWillChange.send()
        }
    }
}
