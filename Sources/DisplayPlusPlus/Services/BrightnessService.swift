import CoreGraphics
import Foundation

/// Brightness for panels macOS owns, plus a last-resort computer-side fallback.
///
/// Two genuinely different controls live here and they must not be confused:
///
/// - **Native** (`DisplayServices`, private but the system's own path). Changes the
///   real backlight, so black stays black and the value is what the brightness keys
///   and Control Center show.
/// - **Software** (gamma transfer table). Scales the signal on its way out. Works on
///   any display, but the panel backlight is untouched: dark areas turn grey and the
///   contrast range shrinks. Only appropriate when nothing else is available, e.g. a
///   display behind a USB-C→HDMI converter that does not forward DDC/CI.
///
/// The two are exposed separately rather than as one "set brightness" that silently
/// picks. A caller that gets the software path should be able to say so in the UI,
/// because the user can see the difference.
final class BrightnessService {
    static let shared = BrightnessService()

    private typealias SetFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias GetFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias CanFn = @convention(c) (CGDirectDisplayID) -> Bool

    private var setFn: SetFn?
    private var getFn: GetFn?
    private var canFn: CanFn?

    /// Software levels per display, so repeated writes compose instead of
    /// stacking gamma tables on top of each other.
    private var softwareLevels: [CGDirectDisplayID: Double] = [:]

    /// Lowest signal scale the software path will apply. Going to true zero makes
    /// a display unreadable and hard to recover from, so the floor leaves the
    /// image dim but present.
    private static let softwareFloor = 0.12

    private init() {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) else {
            return
        }
        if let set = dlsym(handle, "DisplayServicesSetBrightness") {
            setFn = unsafeBitCast(set, to: SetFn?.self)
        }
        if let get = dlsym(handle, "DisplayServicesGetBrightness") {
            getFn = unsafeBitCast(get, to: GetFn?.self)
        }
        if let can = dlsym(handle, "DisplayServicesCanChangeBrightness") {
            canFn = unsafeBitCast(can, to: CanFn?.self)
        }
    }

    // MARK: - Native backlight

    func canControlNatively(_ device: DisplayDevice) -> Bool {
        guard let canFn else { return false }
        return canFn(device.id)
    }

    func nativeLevel(of device: DisplayDevice) -> Double? {
        guard let getFn else { return nil }
        var value: Float = -1
        guard getFn(device.id, &value) == 0, value >= 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    func setNativeLevel(_ value: Double, for device: DisplayDevice) -> Bool {
        guard let setFn else { return false }
        return setFn(device.id, Float(min(max(value, 0), 1))) == 0
    }

    // MARK: - Software dimming

    func softwareLevel(of device: DisplayDevice) -> Double? {
        softwareLevels[device.id]
    }

    /// Applies a gamma-table scale. Composes from 1.0 each time, so dragging the
    /// slider cannot ratchet the image permanently darker.
    @discardableResult
    func setSoftwareLevel(_ value: Double, for device: DisplayDevice) -> Bool {
        let clamped = min(max(value, 0), 1)
        let scale = Float(Self.softwareFloor + (1 - Self.softwareFloor) * clamped)
        let error = CGSetDisplayTransferByFormula(device.id, 0, scale, 1, 0, scale, 1, 0, scale, 1)
        guard error == .success else { return false }
        softwareLevels[device.id] = clamped
        return true
    }

    /// Puts the display back to an untouched transfer table.
    func clearSoftwareLevel(for device: DisplayDevice) {
        guard softwareLevels.removeValue(forKey: device.id) != nil else { return }
        CGSetDisplayTransferByFormula(device.id, 0, 1, 1, 0, 1, 1, 0, 1, 1)
    }

    func clearAllSoftwareLevels() {
        // Restoring every profile is the only way to guarantee nothing is left
        // dimmed if the app goes away unexpectedly.
        softwareLevels.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }
}
