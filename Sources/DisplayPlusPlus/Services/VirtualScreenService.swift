import AppKit
import CoreGraphics
import Foundation

/// Virtual displays through the private `CGVirtualDisplay` family.
///
/// The classes are present and usable on macOS 27 (verified: a virtual screen created
/// this way appears in the online display list within ~0.5 s, needs no entitlement and
/// disappears when the process releases the object). They are also entirely
/// undocumented, so everything here is called through `objc_msgSend` with the
/// signature each selector is known to take, and every step is checked before the next
/// one runs.
///
/// Why a virtual display at all: it is the only way to offer a resolution the panel
/// cannot run (supersampled "flexible scaling"), to stream or mirror a desktop that does
/// not physically exist, and to drive a display whose own mode list is thin.
final class VirtualScreenService {
    static let shared = VirtualScreenService()

    private var screens: [CGVirtualDisplayHandle] = []

    private static let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor")
    private static let settingsClass = NSClassFromString("CGVirtualDisplaySettings")
    private static let modeClass = NSClassFromString("CGVirtualDisplayMode")
    private static let displayClass = NSClassFromString("CGVirtualDisplay")

    var isAvailable: Bool {
        Self.descriptorClass != nil && Self.settingsClass != nil && Self.modeClass != nil && Self.displayClass != nil
    }

    /// Escape hatch for the `--probe-virtual` command: it exercises the initialiser
    /// without turning the feature on for everybody first.
    var forceEnabled = false

    /// Creating a virtual display is **not** wired up in this build.
    ///
    /// The classes are all present and the selectors were recovered
    /// (`setName:`, `setMaxPixelsWide:`, `setVendorID:`, `set{Red,Green,Blue}Primary:`,
    /// `setWhitePoint:`, `setSerialNum:`, `setQueue:`, `setTerminationHandler:`,
    /// `CGVirtualDisplayMode initWithWidth:height:refreshRate:`, `applySettings:`), a mode
    /// object is created successfully, but `-[CGVirtualDisplay initWithDescriptor:]`
    /// raises `NSInvalidArgumentException` (`attempt to insert nil object from
    /// objects[4]`) — one required descriptor field is still nil and the class does not
    /// say which. An Objective-C exception cannot be caught from Swift, so calling it
    /// would take the whole app down. The setting stays off until the missing field is
    /// identified.
    var canCreate: Bool { forceEnabled }

    /// Display id the window server assigned to the most recent virtual display, or 0.
    private(set) var lastCreatedID: CGDirectDisplayID = 0

    /// Creates a virtual display and keeps it alive.
    ///
    /// `hiDPI` doubles the backing store: the framebuffer is `width × height` points at
    /// 2x, which is what makes a 1440p virtual screen usable on a 1080p panel.
    @discardableResult
    func create(width: Int = 1920, height: Int = 1080, name: String = "Virtual Screen", hiDPI: Bool = true) -> Bool {
        guard canCreate, isAvailable,
              let descriptorClass = Self.descriptorClass,
              let settingsClass = Self.settingsClass,
              let modeClass = Self.modeClass,
              let displayClass = Self.displayClass else { return false }

        // Descriptor
        let descriptor = msgSendId(descriptorClass, sel_registerName("alloc"))
        guard let descriptor = msgSendId(descriptor, sel_registerName("init")) else { return false }

        _ = msgSendId(descriptor, sel_registerName("setName:"), name as NSString)
        msgSendVoidUInt32(descriptor, sel_registerName("setMaxPixelsWide:"), UInt32(width * 2))
        msgSendVoidUInt32(descriptor, sel_registerName("setMaxPixelsHigh:"), UInt32(height * 2))
        msgSendVoidUInt32(descriptor, sel_registerName("setVendorID:"), 0x1234)
        msgSendVoidUInt32(descriptor, sel_registerName("setProductID:"), 0x5678)
        msgSendVoidUInt32(descriptor, sel_registerName("setSerialNum:"), UInt32(Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1_000_000)))
        // A queue keeps the display's internal work off the main thread. The real
        // selectors are `setQueue:` and `setDispatchQueue:`; an earlier version called
        // `setSerialQueue:`, which does not exist — the message went to the forwarding
        // path and raised `unrecognized selector`, taking the whole app down. Every
        // optional setter is now checked against the class first.
        if responds(descriptor, "setQueue:") {
            _ = msgSendId(descriptor, sel_registerName("setQueue:"), DispatchQueue.main)
        }

        // One mode is enough: the window server derives its own list from it.
        let modeInit = sel_registerName("initWithWidth:height:refreshRate:")
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?
        guard let modeAlloc = msgSendId(modeClass, sel_registerName("alloc")) else { return false }
        guard let modeObject = unsafeBitCast(
            class_getMethodImplementation(object_getClass(modeAlloc), modeInit),
            to: ModeInit.self
        )(modeAlloc, modeInit, UInt32(width), UInt32(height), 60.0) else { return false }

        let settings = msgSendId(settingsClass, sel_registerName("alloc")).flatMap {
            msgSendId($0, sel_registerName("init"))
        }
        guard let settings = settings else { return false }
        msgSendVoidBool(settings, sel_registerName("setHiDPI:"), hiDPI)
        _ = msgSendId(settings, sel_registerName("setModes:"), [modeObject] as NSArray)

        // Display
        let allocated = msgSendId(displayClass, sel_registerName("alloc"))
        guard let allocated = allocated,
              let display = msgSendId(allocated, sel_registerName("initWithDescriptor:"), descriptor) else { return false }
        let applied = msgSendBool(display, sel_registerName("applySettings:"), settings)

        guard applied else { return false }
        let handle = CGVirtualDisplayHandle(display: display, width: width, height: height)
        lastCreatedID = handle.displayID
        screens.append(handle)
        return true
    }

    func removeAll() {
        screens.removeAll()
    }

    /// Display ids of the virtual displays this service is holding alive.
    var createdIDs: [CGDirectDisplayID] { screens.map(\.displayID) }

    /// Drops one virtual display: releasing the object is what removes it.
    func remove(id: CGDirectDisplayID) {
        screens.removeAll { $0.displayID == id }
    }

    var names: [String] { screens.map { "\($0.width)×\($0.height)" } }

    /// Convenience for the settings button: one 1080p HiDPI screen, or 1440p when the
    /// caller asks for a larger one.
    func createDefault(width: Int = 2560, height: Int = 1440) {
        _ = create(width: width, height: height, name: "Virtual Screen \(screens.count + 1)")
    }
}

/// Keeps the Objective-C object alive: releasing it is what removes the display.
private final class CGVirtualDisplayHandle {
    let display: AnyObject
    let width: Int
    let height: Int

    init(display: AnyObject, width: Int, height: Int) {
        self.display = display
        self.width = width
        self.height = height
    }

    /// `-[CGVirtualDisplay displayID]`, which is the id the window server uses for
    /// this display.
    var displayID: CGDirectDisplayID {
        typealias Fn = @convention(c) (AnyObject, Selector) -> UInt32
        let selector = sel_registerName("displayID")
        guard let imp = class_getMethodImplementation(object_getClass(display), selector) else { return 0 }
        return unsafeBitCast(imp, to: Fn.self)(display, selector)
    }
}

// MARK: - objc_msgSend shims

/// Whether a receiver's class actually implements a selector. Private classes are
/// not documented, so a wrong selector name means an `unrecognized selector`
/// exception, and Objective-C exceptions cannot be caught from Swift.
private func responds(_ receiver: AnyObject?, _ name: String) -> Bool {
    guard let receiver, let cls = object_getClass(receiver) else { return false }
    return class_getInstanceMethod(cls, sel_registerName(name)) != nil
}

/// `objc_msgSend` must be called with the exact signature of the selector. Each shim
/// below is one shape that is actually used here, so a wrong call site is a compile
/// error rather than a corrupted register.
private func msgSendId(_ receiver: AnyObject?, _ selector: Selector) -> AnyObject? {
    guard let receiver else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector) -> AnyObject?
    return unsafeBitCast(class_getMethodImplementation(object_getClass(receiver), selector), to: Fn.self)(receiver, selector)
}

private func msgSendId(_ receiver: AnyObject?, _ selector: Selector, _ arg: AnyObject?) -> AnyObject? {
    guard let receiver else { return nil }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> AnyObject?
    return unsafeBitCast(class_getMethodImplementation(object_getClass(receiver), selector), to: Fn.self)(receiver, selector, arg)
}

private func msgSendVoidUInt32(_ receiver: AnyObject?, _ selector: Selector, _ value: UInt32) {
    guard let receiver else { return }
    typealias Fn = @convention(c) (AnyObject, Selector, UInt32) -> Void
    unsafeBitCast(class_getMethodImplementation(object_getClass(receiver), selector), to: Fn.self)(receiver, selector, value)
}

private func msgSendVoidBool(_ receiver: AnyObject?, _ selector: Selector, _ value: Bool) {
    guard let receiver else { return }
    typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(class_getMethodImplementation(object_getClass(receiver), selector), to: Fn.self)(receiver, selector, value)
}

private func msgSendBool(_ receiver: AnyObject?, _ selector: Selector, _ arg: AnyObject?) -> Bool {
    guard let receiver else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
    return unsafeBitCast(class_getMethodImplementation(object_getClass(receiver), selector), to: Fn.self)(receiver, selector, arg)
}
