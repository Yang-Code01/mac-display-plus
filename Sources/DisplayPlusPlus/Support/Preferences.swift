import Foundation

/// The app's own preferences, in one place.
///
/// Why this exists: the settings window used to hold its switches in local `@State`,
/// which meant they looked live, kept nothing, and constrained nothing. Every switch the
/// user can see is now a key here, and every consumer reads the same key — a switch that
/// is not read by anything is a lie, so any key without a consumer is disabled in the UI
/// instead of being offered.
///
/// Storage is `UserDefaults` (the app has no database and no sync), with a
/// `defaultsChanged` notification so the media-key tap can restart itself without the
/// settings window having to know the tap exists.
enum Preferences {
    /// Posted after any key changes. Deliberately one notification for all keys: the set is
    /// small and every consumer wants "something changed", not a key-by-key feed.
    static let changed = Notification.Name("displaypp.preferencesChanged")

    enum Key: String, CaseIterable {
        case menuRowPrefix = "menuRow."
        case connectOptions = "connectOptions"
        case showDetachedDisplays = "showDetachedDisplays"
        case nativeBrightnessKeys = "nativeBrightnessKeys"
        case nativeVolumeKeys = "nativeVolumeKeys"
        case osdEnabled = "osdEnabled"
        case osdCustomIcons = "osdCustomIcons"
    }

    private static func notify() {
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // MARK: - Typed accessors

    static func bool(_ key: Key, default fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key.rawValue) as? Bool ?? fallback
    }

    static func set(_ key: Key, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key.rawValue)
        notify()
    }

    /// Menu row visibility. Default is visible: the panel is the product, so an unset
    /// key must not hide a row.
    static func menuRowEnabled(_ submenu: AppMenuSubmenu) -> Bool {
        UserDefaults.standard.object(forKey: Key.menuRowPrefix.rawValue + submenu.rawValue) as? Bool ?? true
    }

    static func setMenuRow(_ submenu: AppMenuSubmenu, _ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Key.menuRowPrefix.rawValue + submenu.rawValue)
        notify()
    }

    // MARK: - Consumers' short hands

    /// Whether displays may be disconnected from the menu (header switch + Disconnect row).
    static var connectOptions: Bool { bool(.connectOptions, default: true) }
    /// Whether detached (previously seen, currently offline) displays are listed.
    static var showDetachedDisplays: Bool { bool(.showDetachedDisplays, default: false) }
    static var nativeBrightnessKeys: Bool { bool(.nativeBrightnessKeys, default: true) }
    static var nativeVolumeKeys: Bool { bool(.nativeVolumeKeys, default: false) }
    static var osdEnabled: Bool { bool(.osdEnabled, default: true) }

    // MARK: - Previously seen displays

    /// Displays this app has seen, kept so an offline one can still be listed.
    ///
    /// `CGGetOnlineDisplayList` only reports what is connected right now, so a registry is
    /// kept instead: an unplugged display can still have settings edited. `id → name`,
    /// updated on every enumeration.
    private static let seenKey = "seenDisplays"

    static func rememberSeen(_ devices: [DisplayDevice]) {
        var seen = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String]) ?? [:]
        var changed = false
        for device in devices where seen[String(device.id)] != device.name {
            seen[String(device.id)] = device.name
            changed = true
        }
        if changed { UserDefaults.standard.set(seen, forKey: seenKey) }
    }

    /// Seen displays that are not in `live`.
    static func detachedDisplays(live: Set<UInt32>) -> [(id: UInt32, name: String)] {
        let seen = (UserDefaults.standard.dictionary(forKey: seenKey) as? [String: String]) ?? [:]
        return seen.compactMap { key, name in
            guard let id = UInt32(key), !live.contains(id) else { return nil }
            return (id, name)
        }
        .sorted { $0.id < $1.id }
    }
}
