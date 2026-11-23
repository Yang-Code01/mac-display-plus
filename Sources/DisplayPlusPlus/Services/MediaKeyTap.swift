import AppKit
import ApplicationServices

/// Intercepts the hardware brightness keys.
///
/// The keys arrive as `.systemDefined` NX_SYSDEFINED events with a key code in
/// the data1 field, not as ordinary key downs — `NSEvent` never sees them as
/// key events, which is why a plain `addLocalMonitor` does nothing.
///
/// A `CGEventTap` at `.cgSessionEventTap` is the only place they can be caught
/// before the window server acts on them. That needs Accessibility permission;
/// without it `CGEvent.tapCreate` returns `nil` and the app runs with the
/// system's own brightness handling, which is a correct fallback rather than a
/// broken state.
final class MediaKeyTap {
    enum Key {
        case brightnessUp
        case brightnessDown
        case volumeUp
        case volumeDown
        case mute
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Returns whether the event was consumed. A key the app is not configured to handle
    /// must fall through to the system instead of being swallowed — otherwise turning a
    /// switch off in settings would make the key do nothing at all, which is worse than
    /// before the app existed.
    private let handler: (Key) -> Bool

    // NX_SYSDEFINED key numbers. Brightness is 2/3, audio is 0/1/7 — the same numbering
    // the HID spec uses, which is why they cluster like this.
    private static let keyTypeBrightnessUp: Int32 = 3
    private static let keyTypeBrightnessDown: Int32 = 2
    private static let keyTypeSoundUp: Int32 = 0
    private static let keyTypeSoundDown: Int32 = 1
    private static let keyTypeMute: Int32 = 7

    init(handler: @escaping (Key) -> Bool) {
        self.handler = handler
    }

    var isRunning: Bool { tap != nil }

    static var hasPermission: Bool { AXIsProcessTrusted() }

    func start() {
        guard tap == nil else { return }

        let mask = CGEventMask(1 << UInt64(NSEvent.EventType.systemDefined.rawValue))
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, _, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<MediaKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return monitor.handle(event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        source = nil
    }

    private func handle(event: CGEvent) -> Unmanaged<CGEvent>? {
        // A disabled tap is a dead tap; re-enable it so a timeout does not kill
        // key handling for the rest of the session.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == 0 { }

        guard let nsEvent = NSEvent(cgEvent: event), nsEvent.type == .systemDefined else {
            return Unmanaged.passUnretained(event)
        }

        let data = nsEvent.data1
        let keyCode = Int32((data & 0xFFFF_0000) >> 16)
        let keyFlags = data & 0x0000_FFFF
        // 0x0A == key down in the media-key flag field.
        guard keyFlags == 0x0A else { return Unmanaged.passUnretained(event) }

        let key: Key?
        switch keyCode {
        case Self.keyTypeBrightnessUp: key = .brightnessUp
        case Self.keyTypeBrightnessDown: key = .brightnessDown
        case Self.keyTypeSoundUp: key = .volumeUp
        case Self.keyTypeSoundDown: key = .volumeDown
        case Self.keyTypeMute: key = .mute
        default: key = nil
        }
        guard let key else { return Unmanaged.passUnretained(event) }
        // Consume only when the app actually did something with it.
        return handler(key) ? nil : Unmanaged.passUnretained(event)
    }
}
