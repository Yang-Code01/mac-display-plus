// Runtime probe for the private CGVirtualDisplay family.
//
// `-[CGVirtualDisplay initWithDescriptor:]` fails with
// "attempt to insert nil object from objects[4]", which names an index but not a
// field. This tool dumps the ivar and method layout of the descriptor so the nil
// field can be identified instead of guessed, and can then build a descriptor
// field by field and try the initialiser in a child process.
//
//   probe-vdisplay dump                 ivars, methods, and which ivars are still nil
//   probe-vdisplay try <fields>         build a descriptor and initWithDescriptor:
//
// <fields> is a comma separated list of: name,max,vendor,product,serial,size,
// primaries,whitepoint,queue,dispatchqueue,termination,displayinfo

import AppKit
import CoreGraphics
import Foundation

// MARK: - objc_msgSend shims

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

private func msgSendBool(_ receiver: AnyObject?, _ selector: Selector, _ arg: AnyObject?) -> Bool {
    guard let receiver else { return false }
    typealias Fn = @convention(c) (AnyObject, Selector, AnyObject?) -> Bool
    return unsafeBitCast(class_getMethodImplementation(object_getClass(receiver), selector), to: Fn.self)(receiver, selector, arg)
}

// MARK: - Inspection

private func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

private func describe(_ name: String) {
    guard let cls = NSClassFromString(name) else {
        print("\(name): NOT PRESENT")
        return
    }
    var ivarCount: UInt32 = 0
    if let ivars = class_copyIvarList(cls, &ivarCount) {
        print("== \(name) ivars (\(ivarCount))")
        for i in 0..<Int(ivarCount) {
            let ivar = ivars[i]
            let fieldName = ivar_getName(ivar).map { String(cString: $0) } ?? "?"
            let type = ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "?"
            print("  \(pad(fieldName, 30)) \(pad(type, 24)) off=\(ivar_getOffset(ivar))")
        }
        free(ivars)
    }
    var methodCount: UInt32 = 0
    if let methods = class_copyMethodList(cls, &methodCount) {
        print("== \(name) methods (\(methodCount))")
        for i in 0..<Int(methodCount) {
            let method = methods[i]
            let selector = NSStringFromSelector(method_getName(method))
            let type = method_getTypeEncoding(method).map { String(cString: $0) } ?? "?"
            print("  \(pad(selector, 34)) \(type)")
        }
        free(methods)
    }
}

/// Reads every object-typed ivar of a fresh, unmodified descriptor and reports
/// which are still nil. Pairs with `describe` to name the field index 4 refers to.
private func reportNilIvars() {
    guard let cls = NSClassFromString("CGVirtualDisplayDescriptor") else { return }
    guard let allocated = msgSendId(cls, sel_registerName("alloc")),
          let descriptor = msgSendId(allocated, sel_registerName("init")) else {
        print("descriptor init failed")
        return
    }
    var ivarCount: UInt32 = 0
    guard let ivars = class_copyIvarList(cls, &ivarCount) else { return }
    print("== fresh descriptor: object ivars that are nil")
    for i in 0..<Int(ivarCount) {
        let ivar = ivars[i]
        guard let typePtr = ivar_getTypeEncoding(ivar) else { continue }
        let type = String(cString: typePtr)
        guard type.hasPrefix("@") else { continue }
        let fieldName = ivar_getName(ivar).map { String(cString: $0) } ?? "?"
        let value = object_getIvar(descriptor, ivar) as AnyObject?
        print("  \(pad(fieldName, 30)) \(value == nil ? "nil" : "set")")
    }
    free(ivars)
}

// MARK: - Attempt

/// Builds a descriptor with the requested fields, then runs the initialiser.
/// Run this in a child process: an Objective-C exception here aborts the process.
private func attempt(fields: Set<String>) {
    // Connecting to the window server changes what the display daemon will accept:
    // a bare CLI process gets a display id but nothing is published.
    if fields.contains("gui") {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
    }

    guard let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor"),
          let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
          let modeClass = NSClassFromString("CGVirtualDisplayMode"),
          let displayClass = NSClassFromString("CGVirtualDisplay") else {
        print("classes missing")
        exit(1)
    }
    guard let allocated = msgSendId(descriptorClass, sel_registerName("alloc")),
          let descriptor = msgSendId(allocated, sel_registerName("init")) else {
        print("descriptor init failed")
        exit(1)
    }

    func set(_ key: String, _ value: Any) {
        (descriptor as AnyObject).setValue(value, forKey: key)
        print("  set \(key) = \(value)")
    }

    if fields.contains("name") { set("name", "display++ virtual") }
    if fields.contains("max") {
        set("maxPixelsWide", NSNumber(value: 3840))
        set("maxPixelsHigh", NSNumber(value: 2160))
    }
    if fields.contains("vendor") { set("vendorID", NSNumber(value: 0x1234)) }
    if fields.contains("product") { set("productID", NSNumber(value: 0x5678)) }
    if fields.contains("serial") { set("serialNum", NSNumber(value: 42)) }
    if fields.contains("size") { set("sizeInMillimeters", NSValue(size: CGSize(width: 530, height: 300))) }
    if fields.contains("primaries") {
        set("redPrimary", NSValue(point: CGPoint(x: 0.68, y: 0.32)))
        set("greenPrimary", NSValue(point: CGPoint(x: 0.265, y: 0.69)))
        set("bluePrimary", NSValue(point: CGPoint(x: 0.15, y: 0.06)))
    }
    if fields.contains("whitepoint") { set("whitePoint", NSValue(point: CGPoint(x: 0.3127, y: 0.329))) }
    if fields.contains("queue") { set("queue", DispatchQueue.main) }
    if fields.contains("dispatchqueue") { set("dispatchQueue", DispatchQueue.main) }
    if fields.contains("termination") {
        set("terminationHandler", { () -> Void in } as @convention(block) () -> Void)
    }
    if fields.contains("displayinfo") {
        set("displayInfo", [
            "DisplayProductID": NSNumber(value: 0x5678),
            "DisplayVendorID": NSNumber(value: 0x1234),
            "DisplaySerialNumber": NSNumber(value: 42),
        ])
    }

    // One mode is all the window server needs to derive the rest.
    // transferFunction is a UInt32 on CGVirtualDisplayMode; the three-argument
    // initialiser leaves it at 0, which the window server logs as CDVirtualDisplayModeEOTF = 0.
    let transferFunction = fields.compactMap { field -> UInt32? in
        guard field.hasPrefix("tf") else { return nil }
        return UInt32(field.dropFirst(2))
    }.first
    let mode: AnyObject?
    if let transferFunction {
        let modeInit = sel_registerName("initWithWidth:height:refreshRate:transferFunction:")
        typealias ModeInit4 = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double, UInt32) -> AnyObject?
        guard let modeAlloc = msgSendId(modeClass, sel_registerName("alloc")) else { exit(1) }
        mode = unsafeBitCast(
            class_getMethodImplementation(object_getClass(modeAlloc), modeInit),
            to: ModeInit4.self
        )(modeAlloc, modeInit, 1920, 1080, 60.0, transferFunction)
        print("  mode ok tf=\(transferFunction)")
    } else {
        let modeInit = sel_registerName("initWithWidth:height:refreshRate:")
        typealias ModeInit = @convention(c) (AnyObject, Selector, UInt32, UInt32, Double) -> AnyObject?
        guard let modeAlloc = msgSendId(modeClass, sel_registerName("alloc")) else { exit(1) }
        mode = unsafeBitCast(
            class_getMethodImplementation(object_getClass(modeAlloc), modeInit),
            to: ModeInit.self
        )(modeAlloc, modeInit, 1920, 1080, 60.0)
        print("  mode ok tf=0")
    }
    guard let mode else { print("mode init failed"); exit(1) }

    guard let settingsAlloc = msgSendId(settingsClass, sel_registerName("alloc")),
          let settings = msgSendId(settingsAlloc, sel_registerName("init")) else { exit(1) }
    typealias VoidBool = @convention(c) (AnyObject, Selector, Bool) -> Void
    // setHiDPI: takes UInt32, not BOOL (ivar _hiDPI is I).
    typealias VoidU32 = @convention(c) (AnyObject, Selector, UInt32) -> Void
    let hiDPIValue: UInt32 = fields.contains("hidpi") ? 1 : 0
    unsafeBitCast(class_getMethodImplementation(object_getClass(settings), sel_registerName("setHiDPI:")),
                  to: VoidU32.self)(settings, sel_registerName("setHiDPI:"), hiDPIValue)
    if fields.contains("reference") {
        typealias VoidBool2 = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(class_getMethodImplementation(object_getClass(settings), sel_registerName("setIsReference:")),
                      to: VoidBool2.self)(settings, sel_registerName("setIsReference:"), true)
    }
    print("  settings hiDPI=\(hiDPIValue)")
    _ = msgSendId(settings, sel_registerName("setModes:"), [mode] as NSArray)

    print("  descriptor ready; calling initWithDescriptor:")
    guard let displayAlloc = msgSendId(displayClass, sel_registerName("alloc")),
          let display = msgSendId(displayAlloc, sel_registerName("initWithDescriptor:"), descriptor) else {
        print("  initWithDescriptor returned nil")
        exit(2)
    }
    print("  initWithDescriptor ok")
    typealias U32Get = @convention(c) (AnyObject, Selector) -> UInt32
    if let imp = class_getMethodImplementation(object_getClass(display), sel_registerName("displayID")) {
        let id = unsafeBitCast(imp, to: U32Get.self)(display, sel_registerName("displayID"))
        print("  virtual displayID = \(id)")
    }
    let applied = msgSendBool(display, sel_registerName("applySettings:"), settings)
    print("  applySettings -> \(applied)")

    // A freshly created virtual display can stay offline; the window server's own
    // switch for that is CGSConfigureDisplayEnabled (same symbol the disconnect
    // feature uses). Only attempted when asked for, because it is private.
    let vid = class_getMethodImplementation(object_getClass(display), sel_registerName("displayID"))
        .map { unsafeBitCast($0, to: U32Get.self)(display, sel_registerName("displayID")) } ?? 0
    if fields.contains("enable"), vid != 0 {
        typealias EnableFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Bool) -> Int32
        if let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
           let symbol = dlsym(handle, "CGSConfigureDisplayEnabled") {
            let enable = unsafeBitCast(symbol, to: EnableFn.self)
            var config: CGDisplayConfigRef?
            let began = CGBeginDisplayConfiguration(&config)
            let set = enable(config, vid, true)
            let done = CGCompleteDisplayConfiguration(config, .forSession)
            print("  CGSConfigureDisplayEnabled(begin=\(began.rawValue) set=\(set) complete=\(done.rawValue))")
        }
    }

    // Mirroring the physical panel onto the virtual one is the point of the whole
    // exercise for flexible scaling; it also proves whether the window server will
    // place the new display in the client's layout at all.
    if fields.contains("mirror"), vid != 0 {
        var config: CGDisplayConfigRef?
        let began = CGBeginDisplayConfiguration(&config)
        let mirrored = CGConfigureDisplayMirrorOfDisplay(config, 2, vid)
        let done = CGCompleteDisplayConfiguration(config, .forSession)
        print("  mirror physical->virtual begin=\(began.rawValue) cgmirror=\(mirrored.rawValue) complete=\(done.rawValue) readback=\(CGDisplayMirrorsDisplay(2))")
    }

    // Does merely *having* this virtual display make the window server offer its
    // scaled modes on the physical panel? That is what flexible scaling needs: the
    // panel stays the only screen, it just gains a 2x-backed mode.
    if fields.contains("watchphysical") {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        for step in 0..<8 {
            let physical = (CGDisplayCopyAllDisplayModes(2, options) as? [CGDisplayMode]) ?? []
            let scaled = physical.filter { $0.width == 1600 && $0.pixelWidth > 1600 }
            print("  watch \((step + 1) * 500)ms modes=\(physical.count) scaled1600=\(scaled.map { "\($0.pixelWidth)x\($0.pixelHeight)" }.joined(separator: ","))")
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
    }

    // Hypothesis worth testing: mirroring the panel onto a 2x virtual display of the
    // same size once may leave a scaled 2x mode behind on the panel itself, which would
    // make the HiDPI switch a plain mode change afterwards.
    if fields.contains("unlock") {
        func physicalScaled() -> [String] {
            let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(2, options) as? [CGDisplayMode]) ?? []
            return modes.filter { $0.width == 1600 && $0.pixelWidth > 1600 }.map { "\($0.pixelWidth)x\($0.pixelHeight)" }
        }
        print("  unlock         before mirrored=\(CGDisplayMirrorsDisplay(2)) scaled=\(physicalScaled())")
        var config: CGDisplayConfigRef?
        _ = CGBeginDisplayConfiguration(&config)
        let mirrored = CGConfigureDisplayMirrorOfDisplay(config, 2, vid)
        let done = CGCompleteDisplayConfiguration(config, .forSession)
        print("  unlock         mirror=\(mirrored.rawValue) complete=\(done.rawValue) active2=\(CGDisplayIsActive(2))")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        print("  unlock         while mirrored scaled=\(physicalScaled())")
        var restore: CGDisplayConfigRef?
        _ = CGBeginDisplayConfiguration(&restore)
        let cleared = CGConfigureDisplayMirrorOfDisplay(restore, 2, kCGNullDirectDisplay)
        let done2 = CGCompleteDisplayConfiguration(restore, .forSession)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        print("  unlock         cleared=\(cleared.rawValue) complete=\(done2.rawValue) mirrored=\(CGDisplayMirrorsDisplay(2)) active2=\(CGDisplayIsActive(2)) scaled=\(physicalScaled())")
    }

    // Full sequence: mirror the panel onto the 2x virtual display so the window server
    // synthesises a 1600×900 · 2x mode for the panel, then bind the panel to that mode
    // directly and stop mirroring. If the panel keeps the mode, HiDPI at this size
    // becomes a normal mode switch with no virtual display held afterwards.
    if fields.contains("unlock2") {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        func panelMode(_ pixelWidth: Int, _ pixelHeight: Int) -> CGDisplayMode? {
            let modes = (CGDisplayCopyAllDisplayModes(2, options) as? [CGDisplayMode]) ?? []
            return modes.first { $0.width == 1600 && $0.height == 900 && $0.pixelWidth == pixelWidth && $0.pixelHeight == pixelHeight }
        }
        func restorePanel() {
            guard let plain = panelMode(1600, 900) else { return }
            var config: CGDisplayConfigRef?
            _ = CGBeginDisplayConfiguration(&config)
            _ = CGConfigureDisplayWithDisplayMode(config, 2, plain, nil)
            let done = CGCompleteDisplayConfiguration(config, .forSession)
            print("  unlock2        restore -> \(done.rawValue) current=\(CGDisplayCopyDisplayMode(2).map { "\($0.width)x\($0.height)@\($0.pixelWidth)" } ?? "nil")")
        }

        var config: CGDisplayConfigRef?
        _ = CGBeginDisplayConfiguration(&config)
        let mirrored = CGConfigureDisplayMirrorOfDisplay(config, 2, vid)
        let mirroredDone = CGCompleteDisplayConfiguration(config, .forSession)
        RunLoop.current.run(until: Date().addingTimeInterval(2.5))
        print("  unlock2        mirror=\(mirrored.rawValue)/\(mirroredDone.rawValue) active2=\(CGDisplayIsActive(2)) scaled=\(panelMode(3200, 1800) != nil)")

        guard let scaled = panelMode(3200, 1800) else {
            print("  unlock2        no scaled mode appeared; restoring")
            restorePanel()
            exit(1)
        }
        // Clear the mirror and bind the scaled mode in *one* transaction: dropping the
        // mirror on its own flushes the synthesised mode before it can be adopted.
        var bind: CGDisplayConfigRef?
        _ = CGBeginDisplayConfiguration(&bind)
        let cleared = CGConfigureDisplayMirrorOfDisplay(bind, 2, kCGNullDirectDisplay)
        let bound = CGConfigureDisplayWithDisplayMode(bind, 2, scaled, nil)
        let boundDone = CGCompleteDisplayConfiguration(bind, .permanently)
        print("  unlock2        one transaction: clear=\(cleared.rawValue) bind=\(bound.rawValue) complete=\(boundDone.rawValue)")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let now = CGDisplayCopyDisplayMode(2)
        print("  unlock2        bind=\(bound.rawValue)/\(boundDone.rawValue) current=\(now.map { "\($0.width)x\($0.height) pix=\($0.pixelWidth)" } ?? "nil") active2=\(CGDisplayIsActive(2)) online=\(CGDisplayIsOnline(2))")
        if now?.pixelWidth != 3200 {
            print("  unlock2        binding refused; restoring")
            restorePanel()
            exit(1)
        }
    }

    for step in 0..<(fields.contains("hold") ? 40 : 10) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        var active: UInt32 = 0
        var online: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &active)
        CGGetOnlineDisplayList(0, nil, &online)
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var idCount: UInt32 = 16
        CGGetOnlineDisplayList(16, &ids, &idCount)
        let listed = ids.prefix(Int(idCount)).map(String.init).joined(separator: ",")
        print("  t=\((step + 1) * 500)ms online=\(online)[\(listed)] active=\(active) vid: online=\(CGDisplayIsOnline(vid)) active=\(CGDisplayIsActive(vid))")
        if CGDisplayIsOnline(vid) != 0 { break }
    }
    exit(applied ? 0 : 3)
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "describe":
    for name in ["CGVirtualDisplayDescriptor", "CGVirtualDisplaySettings", "CGVirtualDisplayMode", "CGVirtualDisplay"] {
        describe(name)
    }
case "nil":
    reportNilIvars()
case "list":
    var online: UInt32 = 0
    CGGetOnlineDisplayList(0, nil, &online)
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var count: UInt32 = 16
    CGGetOnlineDisplayList(16, &ids, &count)
    for id in ids.prefix(Int(count)) {
        let name = NSDictionary(contentsOfFile: "/dev/null") as Any
        _ = name
        print("display \(id) online=\(CGDisplayIsOnline(id)) active=\(CGDisplayIsActive(id)) bounds=\(CGDisplayBounds(id))")
    }
    print("count=\(count)")
case "try":
    let fields = Set((args.dropFirst().first ?? "").split(separator: ",").map(String.init))
    print("trying with: \(fields.sorted().joined(separator: ","))")
    attempt(fields: fields)
default:
    print("usage: probe-vdisplay describe|nil|try <fields>")
}
