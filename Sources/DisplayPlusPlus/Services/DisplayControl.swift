import AppKit
import CoreGraphics
import Foundation

/// Topology control: mirroring, the main display, disconnect, and moving a display
/// along the shared-edge layout.
///
/// Everything here ends in a `CGBeginDisplayConfiguration` transaction, because the
/// one-shot calls are session-scoped: they hold only while the process that made them
/// lives, and they poison the transaction that follows (measured: a
/// `CGDisplaySetDisplayMode` immediately before `CGCompleteDisplayConfiguration` makes
/// it fail with `kCGErrorIllegalArgument`). `DisplayManager` documents the same trap.
enum DisplayControl {
    /// `CGSConfigureDisplayEnabled` is what the window server itself uses to take a
    /// display out of the layout, and it is not public. It is worth having because
    /// the public route (`CGConfigureDisplayMirrorOfDisplay`) only re-parents a
    /// display, it does not make it look unplugged. A real disconnect removes the
    /// display from the arrangement and puts it to sleep, which is this.
    ///
    /// The signature was established empirically rather than guessed: the one-shot
    /// two-argument form segfaults, the transaction form
    /// `(CGDisplayConfigRef, CGDirectDisplayID, Bool) -> CGError` returns 0 and
    /// actually flips `CGDisplayIsOnline`. Measured on this machine: disabling the
    /// external display drops the online count 2 → 1, enabling brings it back.
    private static let configureEnabled: (@convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32).self)
    }()

    static var canDisconnect: Bool { configureEnabled != nil }

    // MARK: - Mirroring

    /// Mirrors `device` onto `master`, or clears the mirror relationship when
    /// `master` is nil.
    ///
    /// Mirroring is rejected by the window server for two displays that have no
    /// mode in common, so the result is read back rather than trusted.
    @discardableResult
    static func setMirror(_ device: DisplayDevice, of master: DisplayDevice?) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let target = master.map { $0.id } ?? kCGNullDirectDisplay
        let configured = CGConfigureDisplayMirrorOfDisplay(config, device.id, target)
        guard configured == .success, CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCompleteDisplayConfiguration(config, .forSession)
            return false
        }
        return CGDisplayMirrorsDisplay(device.id) == target
    }

    static func mirrorMaster(of device: DisplayDevice) -> CGDirectDisplayID? {
        let master = CGDisplayMirrorsDisplay(device.id)
        return master == kCGNullDirectDisplay ? nil : master
    }

    // MARK: - Main display

    /// The main display is the one whose origin is (0,0); there is no separate setter.
    /// Translating the whole arrangement so the target lands on the origin is the
    /// only way to move the menu bar without unpicking relative positions.
    @discardableResult
    static func setMain(_ device: DisplayDevice) -> Bool {
        guard let current = origin(of: device.id) else { return false }
        guard current != .zero else { return true }
        let shift = CGPoint(x: -current.x, y: -current.y)
        return translate(device, by: shift)
    }

    // MARK: - Disconnect / reconnect

    @discardableResult
    static func setEnabled(_ device: DisplayDevice, _ enabled: Bool) -> Bool {
        guard let configureEnabled else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let status = configureEnabled(config, device.id, enabled)
        guard status == 0, CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCompleteDisplayConfiguration(config, .forSession)
            return false
        }
        // The call returns before the window server has published the new topology, and
        // the publish is not instant either: measured, re-enabling a display reports
        // offline for longer than the disabling does (the link has to retrain). Poll for
        // the state we asked for instead of reading once and reporting a false negative.
        for _ in 0..<12 {
            usleep(150_000)
            if (CGDisplayIsOnline(device.id) != 0) == enabled { return true }
        }
        return false
    }

    // MARK: - Arrangement

    static func origin(of id: CGDirectDisplayID) -> CGPoint? {
        let bounds = CGDisplayBounds(id)
        return bounds.origin
    }

    /// Moves one display by `shift` while leaving every other display where it is.
    ///
    /// A standalone origin change is silently dropped by the window server, so the
    /// move rides in a transaction that also re-asserts the neighbours' origins.
    @discardableResult
    static func translate(_ device: DisplayDevice, by shift: CGPoint) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        var applied = 0
        for other in DisplayManager.shared.devices {
            guard let origin = origin(of: other.id) else { continue }
            let delta = other.id == device.id ? shift : .zero
            let x = Int32((origin.x + delta.x).rounded())
            let y = Int32((origin.y + delta.y).rounded())
            if CGConfigureDisplayOrigin(config, other.id, x, y) == .success { applied += 1 }
        }
        let completed = CGCompleteDisplayConfiguration(config, .permanently)
        return completed == .success && applied > 0
    }

    // MARK: - Rotation

    /// Rotation is reported but not driven.
    ///
    /// `CGDisplayRotation` is public; there is no public setter. The private routes
    /// are `CGSConfigureDisplayMode` with a mode number taken from the CGS mode list,
    /// or a rotation call inside SkyLight that this system does not export
    /// (`dlsym` found none of `CGSConfigureDisplayRotation`,
    /// `SLSConfigureDisplayRotation`, `CGSSetDisplayRotation`). Rather than ship a
    /// control that guesses at a private ABI, the row states what it found.
    static func rotationDegrees(of id: CGDirectDisplayID) -> Int {
        Int(CGDisplayRotation(id).rounded())
    }

    static var canRotate: Bool { false }
}
