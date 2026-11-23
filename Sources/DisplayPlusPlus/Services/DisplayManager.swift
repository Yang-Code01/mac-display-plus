import AppKit
import CoreGraphics
import Foundation

extension Notification.Name {
    static let displayTopologyChanged = Notification.Name("displaypp.topologyChanged")
    static let displayModeChanged = Notification.Name("displaypp.modeChanged")
}

/// Owns the display list and every CoreGraphics call that mutates it.
///
/// Deliberately the only file that links against display state: views read
/// `devices` and call the intent methods here, so a UI change cannot
/// accidentally become a second source of truth for what is on screen.
final class DisplayManager {
    static let shared = DisplayManager()

    private(set) var devices: [DisplayDevice] = []
    private var isReconfiguring = false
    private var pendingRefresh: DispatchWorkItem?

    private init() {}

    // MARK: - Enumeration

    private typealias DetectFn = @convention(c) () -> Int32
    private lazy var detectDisplays: DetectFn? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW),
              let symbol = dlsym(handle, "SLSDetectDisplays") else { return nil }
        return unsafeBitCast(symbol, to: DetectFn.self)
    }()

    /// Asks the window server to re-detect displays.
    ///
    /// `refresh()` only re-reads what macOS already believes. `SLSDetectDisplays`
    /// asks it to look again, which is what recovers from a half-broken
    /// connection. It does *not* restore a link that renegotiated to a lower rate
    /// — that needs a physical replug — but it is the strongest request available
    /// without one.
    func redetectDisplays() {
        _ = detectDisplays?()
        refresh()
    }

    func start() {
        // Bisect hook: registering the reconfiguration callback is the one piece
        // of process-level display state we install, so it can be ruled out.
        if ProcessInfo.processInfo.environment["DPP_NO_CALLBACK"] != nil {
            refresh()
            return
        }
        CGDisplayRegisterReconfigurationCallback({ _, _, _ in
            // Apple is explicit that you must not change display state from
            // inside this callback. Hop out and debounce instead, otherwise a
            // mode switch fires a second reconfiguration mid-flight.
            DispatchQueue.main.async { DisplayManager.shared.scheduleRefresh() }
        }, nil)
        refresh()
    }

    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func refresh() {
        guard !isReconfiguring else { return }
        isReconfiguring = true
        defer { isReconfiguring = false }

        let externalUnits = DisplayManager.externalAVUnits()
        var externalCursor = 0

        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: max(1, Int(count)))
        CGGetOnlineDisplayList(count, &ids, &count)

        let names = DisplayManager.screenNameMap()
        var built: [DisplayDevice] = []

        for id in ids.prefix(Int(count)) {
            // Mirror slaves have no independent mode of their own; listing them
            // would offer the user controls that silently do nothing.
            if CGDisplayMirrorsDisplay(id) != kCGNullDirectDisplay { continue }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            var unit: Int?
            if !builtIn, externalCursor < externalUnits.count {
                unit = externalUnits[externalCursor]
                externalCursor += 1
            }
            let device = DisplayDevice(
                id: id,
                name: names[id] ?? (builtIn ? "Built-in Display" : "Display \(id)"),
                isBuiltIn: builtIn,
                isMain: CGDisplayIsMain(id) != 0,
                avUnit: unit
            )
            // Carry over live control values so the UI does not blink to empty
            // every time a display is reconfigured.
            if let previous = devices.first(where: { $0.id == id }) {
                device.brightness = previous.brightness
                device.contrast = previous.contrast
                device.ddcAvailable = previous.ddcAvailable
            }
            device.modes = DisplayManager.fetchModes(for: id)
            device.currentMode = DisplayManager.captureMode(for: id)
            built.append(device)
        }

        // External first, built-in last: the built-in panel is usually on the right of
        // the arrangement, and the sections should read in the same order as the desktop.
        // Within a group the main display leads, then the id keeps it stable.
        //
        // The registry is what lets the settings window list a display that is offline
        // (`showDetachedDisplays`), so it must include this pass.
        Preferences.rememberSeen(built)
        built.sort { lhs, rhs in
            if lhs.isBuiltIn != rhs.isBuiltIn { return !lhs.isBuiltIn }
            if lhs.isMain != rhs.isMain { return lhs.isMain }
            return lhs.id < rhs.id
        }
        devices = built
        NotificationCenter.default.post(name: .displayTopologyChanged, object: nil)
    }

    /// `DCPAVServiceProxy` units in registry order. DDC only ever talks to the
    /// external ones; touching the embedded proxy crashes in IOKit.
    private static func externalAVUnits() -> [Int] {
        var units: [Int] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("DCPAVServiceProxy")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return units
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String, location == "External" else { continue }
            let unit = IORegistryEntryCreateCFProperty(service, "Unit" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? Int
            units.append(unit ?? units.count)
        }
        return units
    }

    private static func screenNameMap() -> [CGDirectDisplayID: String] {
        var map: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            map[number.uint32Value] = screen.localizedName
        }
        return map
    }

    // MARK: - Modes

    /// The single most important line in the app: without
    /// `kCGDisplayShowDuplicateLowResolutionModes` CoreGraphics hides every
    /// HiDPI variant and a Retina panel reports 10 modes instead of 20.
    private static func fetchModes(for id: CGDirectDisplayID) -> [DisplayModeInfo] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let raw = CGDisplayCopyAllDisplayModes(id, options) else { return [] }

        var seen = Set<DisplayModeInfo>()
        var out: [DisplayModeInfo] = []
        let modes = raw as! [CGDisplayMode]
        for candidate in modes {
            guard candidate.width > 0, candidate.height > 0 else { continue }
            let info = DisplayModeInfo(
                width: candidate.width,
                height: candidate.height,
                pixelWidth: candidate.pixelWidth,
                pixelHeight: candidate.pixelHeight,
                refreshRate: candidate.refreshRate.rounded()
            )
            guard !seen.contains(info) else { continue }
            seen.insert(info)
            out.append(info)
        }

        // CoreGraphics is not the whole list. The window server also holds supersampled
        // modes — 1600 × 900 at a 3200 × 1800 framebuffer on this 1080p panel — which is
        // exactly the mode the HiDPI row needs. Merge in whatever
        // the CGS table has that CoreGraphics did not report, keeping the mode number so
        // the row can actually be applied.
        if DisplayModeTable.isAvailable {
            for mode in DisplayModeTable.modes(for: id) {
                let info = mode.info
                guard !seen.contains(info) else { continue }
                seen.insert(info)
                out.append(info)
            }
        }
        // Width ascending keeps the resolution slider monotonic in "how much
        // desktop do I get". HiDPI wins ties so the sharper variant sits nearer
        // the thumb when both scale classes share a size.
        return out.sorted { lhs, rhs in
            if lhs.width != rhs.width { return lhs.width < rhs.width }
            if lhs.height != rhs.height { return lhs.height < rhs.height }
            if lhs.isHiDPI != rhs.isHiDPI { return lhs.isHiDPI }
            return lhs.refreshRate < rhs.refreshRate
        }
    }

    private static func captureMode(for id: CGDirectDisplayID) -> DisplayModeInfo? {
        guard let mode = CGDisplayCopyDisplayMode(id) else { return nil }
        return DisplayModeInfo(
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            pixelHeight: mode.pixelHeight,
            refreshRate: mode.refreshRate.rounded()
        )
    }


    // MARK: - Intents

    /// Modes matching `info`, drawn from the live system list.
    ///
    /// Two lifetimes matter here and both are easy to get wrong:
    ///
    /// 1. `CGDisplayMode` handles are only valid for the configuration they were
    ///    captured in, so reusing a stored handle after a mode change silently
    ///    fails — including "switch back to what I had".
    /// 2. The array from `CGDisplayCopyAllDisplayModes` owns the handles. Taking
    ///    one element out and letting the array die leaves a dangling reference,
    ///    and every call then fails with `kCGErrorIllegalArgument` (1001) rather
    ///    than crashing, which reads like a permissions problem and is not.
    ///
    /// So the pool is returned and kept alive by the caller for the duration of
    /// the switch.
    /// Only speaks when `DPP_DEBUG` is set. Display changes fail in ways that are
    /// invisible from the UI (the mode simply does not change), so there has to be
    /// a way to see the underlying `CGError`.
    /// Global origins of every active display, i.e. the arrangement the user set up.
    ///
    /// A mode change makes the window server re-anchor displays: it keeps the edge
    /// that touches the main display fixed, so a display above the main one is moved
    /// by however much its height changed. Two displays end up adjacent either way,
    /// but a three-display layout loses its offsets and reads as "my arrangement
    /// changed". Capturing the origins and writing them back explicitly is the only
    /// way to keep what the user chose.
    struct Arrangement: Equatable {
        /// Global bounds per display. Full rects, not just origins: deciding whether
        /// a position is still legal after a resize needs the neighbours' extents.
        var bounds: [CGDirectDisplayID: CGRect]

        var isEmpty: Bool { bounds.isEmpty }

        static func capture() -> Arrangement {
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: max(1, Int(count)))
            CGGetActiveDisplayList(count, &ids, &count)
            var bounds: [CGDirectDisplayID: CGRect] = [:]
            for id in ids.prefix(Int(count)) {
                bounds[id] = CGDisplayBounds(id)
            }
            return Arrangement(bounds: bounds)
        }

        /// True when placing `id` at its recorded position with `size` would collide
        /// with any other display. The window server rejects overlaps, so pinning an
        /// overlapping origin makes it shove the display sideways instead of keeping
        /// the layout.
        func wouldOverlap(_ id: CGDirectDisplayID, size: CGSize) -> Bool {
            guard let origin = bounds[id]?.origin else { return true }
            let candidate = CGRect(origin: origin, size: size)
            return bounds.contains { other, rect in
                other != id && candidate.intersects(rect)
            }
        }

        /// Writes every recorded origin back in one transaction.
        @discardableResult
        func restore() -> Bool {
            guard !bounds.isEmpty else { return false }
            var ref: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&ref) == .success, let config = ref else { return false }
            var touched = false
            for (id, rect) in bounds {
                // Displays can disappear between capture and restore; skip the gone
                // ones rather than failing the whole transaction.
                guard CGDisplayIsActive(id) != 0 else { continue }
                if CGConfigureDisplayOrigin(config, id, Int32(rect.origin.x.rounded()), Int32(rect.origin.y.rounded())) == .success {
                    touched = true
                }
            }
            guard touched else {
                CGCompleteDisplayConfiguration(config, .forSession)
                return false
            }
            return CGCompleteDisplayConfiguration(config, .permanently) == .success
        }
    }

    /// Origins as they are right now, for callers that want to detect drift.
    func currentArrangement() -> Arrangement { Arrangement.capture() }

    private func debugLog(_ message: String) {
        guard ProcessInfo.processInfo.environment["DPP_DEBUG"] != nil else { return }
        FileHandle.standardError.write(Data("display: \(message)\n".utf8))
    }

    /// Lands a mode change.
    ///
    /// Everything here stays in one scope on purpose. A `CGDisplayMode` handle is
    /// only valid while the `CFArray` that returned it is alive, and that
    /// ownership does **not** survive being passed out of the function that
    /// fetched it — the mode then still looks usable but every call to apply it
    /// fails with `kCGErrorIllegalArgument` (1001). Serialising the arrays across
    /// a helper boundary produced exactly that, so the lookup and the switch are
    /// deliberately not split up.
    /// Like `apply`, but tries every variant of the same logical row before giving
    /// up.
    ///
    /// CoreGraphics refuses some refresh-rate/pixel variants while a sibling of the
    /// same size applies fine — on this AOC panel 12 of 29 rows are unsettable in
    /// every variant, but others fail only on the variant the UI happened to keep.
    /// Without this the resolution simply looks broken.
    @discardableResult
    func applyRow(_ mode: DisplayModeInfo, to device: DisplayDevice) -> Bool {
        // Snapshot once here, not inside `apply`: a refused attempt can move the
        // layout too, and re-capturing would record the drifted state as "original".
        let arrangement = Arrangement.capture()
        let sameRow = device.allSelectableModes.filter { $0.rowKey == mode.rowKey }
        // Prefer the variant with the same refresh rate the user is already at, so
        // a size change does not also drop the frame rate.
        let currentRefresh = device.currentMode?.refreshRate
        let ordered = sameRow.sorted { lhs, rhs in
            let lhsMatch = currentRefresh.map { abs($0 - lhs.refreshRate) < 0.6 } ?? false
            let rhsMatch = currentRefresh.map { abs($0 - rhs.refreshRate) < 0.6 } ?? false
            if lhsMatch != rhsMatch { return lhsMatch }
            return lhs.refreshRate > rhs.refreshRate
        }
        for candidate in ordered where apply(candidate, to: device, restoring: arrangement) {
            return true
        }
        return false
    }

    @discardableResult
    func apply(_ mode: DisplayModeInfo, to device: DisplayDevice, restoring: Arrangement? = nil) -> Bool {
        // A row that only exists in the window server's table (supersampled HiDPI) cannot
        // be resolved through `CGDisplayCopyAllDisplayModes` at all — apply it by number.
        if let number = mode.cgsModeNumber {
            let arrangement = restoring ?? Arrangement.capture()
            var pins: [CGDirectDisplayID: CGPoint] = [:]
            for (id, rect) in arrangement.bounds where id != device.id { pins[id] = rect.origin }
            guard DisplayModeTable.apply(modeNumber: number, to: device.id, pinning: pins) else {
                debugLog("apply(cgs): mode \(number) refused by \(device.name)")
                refresh()
                return false
            }
            // Read back rather than trust the return code: a mode can be accepted and the
            // display then stay on the old timing.
            let landed = CGDisplayCopyDisplayMode(device.id).map {
                $0.width == mode.width && $0.pixelWidth == mode.pixelWidth
            } ?? false
            refresh()
            if landed {
                NotificationCenter.default.post(name: .displayModeChanged, object: device)
            }
            return landed
        }

        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let pool = CGDisplayCopyAllDisplayModes(device.id, options) as? [CGDisplayMode] else {
            debugLog("apply: no mode list for \(device.name)")
            refresh()
            return false
        }
        // The predicate reads properties only and never hands `$0` to another
        // Swift function. `CGDisplayMode` elements of a bridged mode array are
        // borrowed, not owned: passing one into a Swift function applies the
        // owned convention and releases it once too often, leaving a dangling
        // handle that makes every later apply fail with 1001.
        guard let resolved = pool.first(where: {
            $0.width == mode.width
                && $0.height == mode.height
                && $0.pixelWidth == mode.pixelWidth
                && $0.pixelHeight == mode.pixelHeight
                && abs($0.refreshRate - mode.refreshRate) < 0.6
        }) else {
            debugLog("apply: mode \(mode.fullLabel) is no longer offered by \(device.name)")
            refresh()
            return false
        }

        debugLog("apply: dev=\(device.id) pool=\(pool.count) want=\(mode.width)x\(mode.height) pix=\(mode.pixelWidth)x\(mode.pixelHeight)@\(mode.refreshRate) resolved=\(resolved.width)x\(resolved.height) pix=\(resolved.pixelWidth)x\(resolved.pixelHeight)@\(resolved.refreshRate) flags=0x\(String(resolved.ioFlags, radix: 16))")

        // Remember the layout before touching anything.
        let arrangement = restoring ?? Arrangement.capture()

        // Suppress the reconfiguration callback storm; state is published below.
        isReconfiguring = true
        defer { isReconfiguring = false }

        // Only the transaction persists. `CGDisplaySetDisplayMode` is
        // session-scoped: the mode holds while this process lives and is rolled
        // back the moment it exits, which for a menu-bar app looks like "it
        // forgets my resolution". Worse, calling it immediately before a
        // transaction poisons the next `CGCompleteDisplayConfiguration`, which
        // then fails with kCGErrorIllegalArgument — which is what made this look
        // like a permissions problem earlier. So the one-shot path is not used at
        // all, and a failed transaction is retried once rather than replaced.
        //
        // The arrangement has to ride along in the *same* transaction. A separate
        // `CGConfigureDisplayOrigin` transaction is accepted and then silently
        // dropped by the window server, which is why the layout kept changing:
        // the mode landed, the origin restore did not. Measured on this machine:
        // a standalone origin change from (1440,-720) to (840,-720) reports
        // success and leaves the display at (1440,-720); the same call bundled
        // with a mode change moves it.
        var landed = false
        for attempt in 0..<2 {
            var ref: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&ref) == .success, let config = ref else {
                debugLog("apply: CGBeginDisplayConfiguration failed (attempt \(attempt))")
                continue
            }
            let configured = CGConfigureDisplayWithDisplayMode(config, device.id, resolved, nil)

            // Pin every display EXCEPT the one changing mode.
            //
            // Pinning the changed display looks safer but backfires: its new size
            // usually overlaps the old position, the window server refuses the
            // overlap, and it resolves that by shoving the display sideways. Left
            // alone it keeps the display's offset and only slides it along the axis
            // needed to stay flush — which is the behaviour the user expects.
            // Its neighbours are a different matter: nothing about their own geometry
            // changed, so they must not move at all.
            var pinned = 0
            let newSize = CGSize(width: mode.width, height: mode.height)
            for (id, rect) in arrangement.bounds where CGDisplayIsActive(id) != 0 {
                // The display that is changing keeps its position too, as long as
                // the new size still fits there. When it does not, the window server
                // slides it along the axis it needs to stay flush — the least
                // disruptive outcome, and better than pinning and getting shoved.
                if id == device.id, arrangement.wouldOverlap(id, size: newSize) { continue }
                if CGConfigureDisplayOrigin(config, id,
                                            Int32(rect.origin.x.rounded()),
                                            Int32(rect.origin.y.rounded())) == .success {
                    pinned += 1
                }
            }

            let completed = CGCompleteDisplayConfiguration(config, .permanently)
            if configured == .success, completed == .success {
                debugLog("apply: landed \(mode.fullLabel) pinned \(pinned)/\(arrangement.bounds.count) origins")
                landed = true
                break
            }
            debugLog("apply: attempt \(attempt) configured=\(configured.rawValue) completed=\(completed.rawValue)")
            Thread.sleep(forTimeInterval: 0.15)
        }

        // A successful transaction is not proof the display accepted the mode: some
        // entries are accepted and then immediately reverted, which used to leave the
        // caller reporting success while nothing on screen changed. Read back.
        if landed {
            var took = false
            for _ in 0..<12 {
                Thread.sleep(forTimeInterval: 0.02)
                if let now = CGDisplayCopyDisplayMode(device.id),
                   now.width == mode.width, now.height == mode.height,
                   now.pixelWidth == mode.pixelWidth, now.pixelHeight == mode.pixelHeight {
                    took = true
                    break
                }
            }
            if !took {
                debugLog("apply: \(mode.fullLabel) was accepted then reverted")
                landed = false
            }
        }

        guard landed else {
            debugLog("apply: could not land \(mode.fullLabel) on \(device.name) -- marking unselectable")
            device.refusedModes.insert(mode.rowKey)
            NotificationCenter.default.post(name: .displayModeChanged, object: device)
            refresh()
            return false
        }

        device.currentMode = mode

        NotificationCenter.default.post(name: .displayModeChanged, object: device)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
        return true
    }

    /// Step `offset` rows along the resolution list. Used by the slider and by
    /// shortcuts so both move through exactly the same sequence.
    @discardableResult
    func stepResolution(_ device: DisplayDevice, by offset: Int) -> Bool {
        let choices = device.sliderChoices
        guard let current = device.currentMode,
              let index = choices.firstIndex(where: {
                  $0.width == current.width && $0.height == current.height && $0.isHiDPI == current.isHiDPI
              }) else { return false }
        let next = min(max(index + offset, 0), choices.count - 1)
        guard next != index else { return false }
        return applyRow(choices[next], to: device)
    }

    @discardableResult
    func setResolution(_ device: DisplayDevice, atSliderValue value: Double) -> Bool {
        let choices = device.sliderChoices
        guard !choices.isEmpty else { return false }
        let index = Int((value * Double(choices.count - 1)).rounded())
        return applyRow(choices[min(max(index, 0), choices.count - 1)], to: device)
    }

    func setRefreshRate(_ rate: Double, for device: DisplayDevice) -> Bool {
        guard let current = device.currentMode else { return false }
        let candidates = device.usableModes.filter {
            $0.width == current.width && $0.height == current.height
                && $0.isHiDPI == current.isHiDPI && abs($0.refreshRate - rate) < 0.5
        }
        guard let mode = candidates.first else { return false }
        return applyRow(mode, to: device)
    }

    /// The same physical resolution at the other backing scale.
    ///
    /// HiDPI is a property of a *pixel* size, not a point size. This panel offers
    /// 1920x1080 at 1x and 960x540 at 2x, and both drive 1920x1080 real pixels.
    /// Pairing on pixel size is what makes the toggle available at *every*
    /// resolution; pairing on point size only ever matched the handful of sizes that
    /// happen to have a same-point 2x twin, which read as "HiDPI is locked".
    ///
    /// Same-point-size is kept as a secondary source because some panels expose a 2x
    /// mode whose backing differs (supersampled entries) and those are still valid
    /// targets.
    /// Modes the toggle may switch to, best first.
    ///
    /// Only **same-desktop-size** twins are offered: `1600 × 900 · 1x ↔ 1600 × 900 · 2x`.
    /// That is what makes the control mean "same layout, twice the pixels" instead of
    /// an unexplained zoom.
    ///
    /// An earlier version also offered the same-*backing-pixel* variant as a fallback
    /// (at 1600×900 · 1x that is `800 × 450 · 2x`). Measured on the external AOC over
    /// HDMI→DP: macOS synthesises that entry from a 4:3 low-resolution mode, it carries
    /// the valid flag, and every attempt fails with `kCGErrorIllegalArgument (1001)`.
    /// The row therefore looked enabled, ate the tap, recorded the refusal and went grey
    /// for the rest of the session — a control that reports "unavailable" only after you
    /// use it. A disabled row that says why is the honest version of that.
    func hiDPICandidates(of device: DisplayDevice) -> [DisplayModeInfo] {
        guard let current = device.currentMode else { return [] }
        let wantHiDPI = !current.isHiDPI
        var seen = Set<String>()
        var candidates = device.usableModes
            .filter {
                $0.isHiDPI == wantHiDPI
                    && $0.width == current.width
                    && $0.height == current.height
            }
            .filter { seen.insert($0.rowKey).inserted }

        // The CGS table is authoritative and strictly larger. On this panel the 2x twin
        // of 1600 × 900 exists only there, which is why the HiDPI row used to be a dead
        // button on the external display.
        if wantHiDPI, DisplayModeTable.isAvailable {
            let twins = DisplayModeTable.hiDPITwins(of: device.id, width: current.width, height: current.height)
            for twin in twins where !seen.contains(twin.info.rowKey) {
                seen.insert(twin.info.rowKey)
                candidates.insert(twin.info, at: 0)
            }
        }
        return candidates
    }

    /// Whether this display exposes a HiDPI twin for the current mode.
    func hasHiDPIPair(_ device: DisplayDevice) -> Bool { !hiDPICandidates(of: device).isEmpty }

    @discardableResult
    func toggleHiDPI(_ device: DisplayDevice) -> Bool {
        // Direction is read from the window server, not from the cached model: after a
        // switch `refresh()` replaces the device objects, so a caller holding the previous
        // object would otherwise toggle in the same direction twice (measured: HiDPI on,
        // then "off" turned it on again).
        if let live = CGDisplayCopyDisplayMode(device.id) {
            let divergent = device.currentMode.map {
                $0.width != live.width || $0.pixelWidth != live.pixelWidth
            } ?? true
            if divergent { refresh() }
        }
        let current = self.device(for: device.id) ?? device
        for candidate in hiDPICandidates(of: current) where applyRow(candidate, to: current) {
            return true
        }
        return false
    }

    func setMain(_ device: DisplayDevice) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        CGConfigureDisplayOrigin(config, device.id, 0, 0)
        CGCompleteDisplayConfiguration(config, .permanently)
    }

    func device(for id: CGDirectDisplayID) -> DisplayDevice? {
        devices.first { $0.id == id }
    }
}
