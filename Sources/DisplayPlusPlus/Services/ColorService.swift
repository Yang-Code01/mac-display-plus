import AppKit
import ColorSync
import CoreGraphics
import Foundation

/// Display colour profiles, read and (attempted) write.
///
/// Reading is straightforward: `ColorSyncDeviceCopyDeviceInfo` returns, per display, a
/// `CustomProfiles` dictionary and a `FactoryProfiles` one keyed by profile id. Measured on
/// this machine:
///
/// ```
/// display 2 (2490W1) uuid 93F4ADE4-…
///   FactoryProfiles { "HDMI HD" {DeviceProfileURL=…2490W1-93F4….icc},
///                     "HDMI SD" {DeviceProfileURL=…/SD 170M-A.icc} }
///   DeviceDefaultProfileID = "HDMI HD"          (absent → the factory profile is in use)
///   CustomProfiles = {}                         (absent → nothing user-set)
/// ```
///
/// Writing is the part that does not work from a plain process: every documented shape of
/// `ColorSyncDeviceSetCustomProfiles` returns `false` here (see `--color-test`). The device
/// info reports `DeviceUserScope = kCFPreferencesAnyUser` with
/// `DeviceHostScope = kCFPreferencesCurrentHost`, i.e. the profile lives in
/// `/Library/Preferences/com.apple.ColorSyncDisplay.plist` — an any-user preference, which
/// needs authorisation. So the UI lists profiles and states why applying is refused instead
/// of offering a button that quietly does nothing.
enum ColorService {
    struct Profile: Hashable {
        let url: URL
        let name: String
        let isFactory: Bool
    }

    private static var displayClass: CFString { kColorSyncDisplayDeviceClass.takeUnretainedValue() as CFString }

    static func uuid(of display: CGDirectDisplayID) -> CFUUID? {
        CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue()
    }

    static func deviceInfo(_ display: CGDirectDisplayID) -> NSDictionary? {
        guard let uuid = uuid(of: display),
              let raw = ColorSyncDeviceCopyDeviceInfo(displayClass, uuid)?.takeRetainedValue()
        else { return nil }
        // Forced cast on purpose: the conditional `as? NSDictionary` returns nil for this
        // CFDictionary while the forced cast succeeds, which is the whole reason every
        // profile lookup looked empty. Type-checked first so a surprise cannot crash.
        guard CFGetTypeID(raw) == CFDictionaryGetTypeID() else { return nil }
        return unsafeBitCast(raw, to: NSDictionary.self)
    }

    /// The profile currently in use, custom if one is set, otherwise the factory default.
    ///
    /// The dictionaries come back as `NSDictionary` with `NSNumber`-and-`String` keys mixed,
    /// so a Swift `[String: String]` cast silently fails and every display looks like it has
    /// no profile at all (measured: `current: —` for both displays). Everything here goes
    /// through `NSDictionary` and stringifies keys instead.
    /// Reads a value out of the CFDictionary ColorSync hands back.
    ///
    /// Swift's bridging is not reliable here: the keys are in `allKeys`, the value prints as a
    /// full dictionary, and `as? NSDictionary` / `dictionary.object(forKey:)` with the key
    /// object still yield nil (measured repeatedly). Going through CFDictionary's own lookup
    /// with the key bridged to CFString is what actually returns the value, so all reads here
    /// are CF-level.
    private static func cfValue(_ dictionary: CFDictionary, _ name: String) -> AnyObject? {
        let key = name as CFString
        guard let raw = CFDictionaryGetValue(dictionary, Unmanaged.passUnretained(key).toOpaque()) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
    }

    private static func asDictionary(_ value: AnyObject?) -> CFDictionary? {
        guard let value else { return nil }
        let type = CFGetTypeID(value)
        guard type == CFDictionaryGetTypeID() else { return nil }
        return (value as! CFDictionary)
    }

    /// `as? String` fails on these CFStrings; `NSString` bridging is the one that works.
    private static func string(_ value: AnyObject?) -> String? {
        guard let value else { return nil }
        if let string = value as? String { return string }
        if CFGetTypeID(value) == CFStringGetTypeID() { return (value as! NSString) as String }
        return nil
    }

    static func currentProfileURL(_ display: CGDirectDisplayID) -> URL? {
        guard let info = deviceInfo(display) as CFDictionary? else { return nil }
        if let custom = asDictionary(cfValue(info, "CustomProfiles")) {
            for key in (custom as NSDictionary).allKeys {
                guard let raw = string(CFDictionaryGetValue(custom, Unmanaged.passUnretained(key as AnyObject).toOpaque()).flatMap { Unmanaged<AnyObject>.fromOpaque($0).takeUnretainedValue() }),
                      let url = URL(string: raw) else { continue }
                return url
            }
        }
        if let factory = asDictionary(cfValue(info, "FactoryProfiles")) {
            func url(of entry: AnyObject?) -> URL? {
                guard let entry = asDictionary(entry), let raw = string(cfValue(entry, "DeviceProfileURL")) else { return nil }
                return URL(string: raw)
            }
            if let id = string(cfValue(factory, "DeviceDefaultProfileID")), let url = url(of: cfValue(factory, id)) {
                return url
            }
            for key in (factory as NSDictionary).allKeys {
                guard let raw = CFDictionaryGetValue(factory, Unmanaged.passUnretained(key as AnyObject).toOpaque()) else { continue }
                let entry = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
                if let url = url(of: entry) { return url }
            }
        }
        return nil
    }

    /// Every profile the user could pick: the display's own factory profiles first, then the
    /// shareable ICC files installed on this machine.
    ///
    /// Profiles this app itself created in earlier runs (`display++ 1600×900 2x-<uuid>.icc`,
    /// from gamma-based software dimming) are filtered out: they are scratch files, not
    /// profiles a user chose.
    static func profiles(for display: CGDirectDisplayID) -> [Profile] {
        var out: [Profile] = []
        if let info = deviceInfo(display) as CFDictionary?,
           let factory = asDictionary(cfValue(info, "FactoryProfiles")) {
            for key in (factory as NSDictionary).allKeys {
                guard let raw = CFDictionaryGetValue(factory, Unmanaged.passUnretained(key as AnyObject).toOpaque()),
                      let entry = asDictionary(Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()),
                      let urlRaw = string(cfValue(entry, "DeviceProfileURL")),
                      let url = URL(string: urlRaw) else { continue }
                out.append(Profile(url: url, name: String(describing: key), isFactory: true))
            }
        }
        let directories = [
            "/Library/ColorSync/Profiles/Displays",
            "/System/Library/ColorSync/Profiles/Displays",
            "/Library/ColorSync/Profiles",
            NSHomeDirectory() + "/Library/ColorSync/Profiles"
        ]
        var seen = Set(out.map(\.url))
        for directory in directories {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { continue }
            for name in names where name.lowercased().hasSuffix(".icc") {
                guard !name.hasPrefix("display++") else { continue }
                let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
                guard seen.insert(url).inserted else { continue }
                out.append(Profile(url: url, name: name.replacingOccurrences(of: ".icc", with: ""), isFactory: false))
            }
        }
        return out
    }

    /// Attempts to install a profile.
    ///
    /// Returns what actually happened: `true` only when reading the profile back reports the
    /// new URL, because the call itself returning `true` on this system is not something that
    /// happens — every shape tried returned `false`.
    @discardableResult
    static func apply(_ url: URL, to display: CGDirectDisplayID) -> Bool {
        guard let uuid = uuid(of: display) else { return false }
        let payload: NSDictionary = ["CustomProfiles": ["1": url.absoluteString]]
        let ok = ColorSyncDeviceSetCustomProfiles(displayClass, uuid, payload)
        usleep(400_000)
        let landed = currentProfileURL(display)?.standardizedFileURL == url.standardizedFileURL
        return ok && landed
    }

    /// Why applying is refused, in one sentence for the UI.
    static var writeRefusalReason: String {
        L("macOS stores the display profile as an any-user preference (/Library/Preferences/com.apple.ColorSyncDisplay.plist), so ColorSyncDeviceSetCustomProfiles needs authorisation this app does not have. The list is real; applying is refused and says so.")
    }
}
