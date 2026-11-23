import CoreFoundation
import Foundation
import IOKit

/// DDC/CI over I2C, the way macOS actually exposes it on Apple Silicon.
///
/// The public story is that DDC needs libusb or a kernel extension. It doesn't:
/// every external display has a `DCPAVServiceProxy` IOKit node, and IOKit's
/// private `IOAVService*` functions let a normal-signed app transact on its I2C
/// bus. Nothing here needs root, a helper daemon, or SIP changes.
///
/// Two traps that cost real debugging time and are worth keeping in the code:
///
/// 1. `IOAVService` is a 24-byte heap object, **not** an `io_object_t`. Typing it
///    as `io_object_t` (32-bit) truncates the pointer and dereferencing the
///    truncation segfaults inside IOKit at `IOAVServiceWriteI2C+68`.
/// 2. The embedded proxy serves the built-in panel, which has no DDC bus. Writing
///    to it also segfaults. Only ever touch `Location == "External"`.
final class DDCService {
    static let shared = DDCService()

    // VCP codes worth knowing. The first three cover everything the panel shows.
    enum VCP {
        static let brightness: UInt8 = 0x10
        static let contrast: UInt8 = 0x12
        static let volume: UInt8 = 0x62
        static let inputSource: UInt8 = 0x60
        static let mute: UInt8 = 0x8D
        /// Reads `nil` from `read`; only answers a write.
        static let powerMode: UInt8 = 0xD6
    }

    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias WriteFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> kern_return_t
    private typealias ReadFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> kern_return_t

    private var createFn: CreateFn?
    private var writeFn: WriteFn?
    private var readFn: ReadFn?

    /// I2C multiplexes; two concurrent transactions alias into each other. One
    /// queue for the whole process keeps our own framing correct, and sleeping
    /// inside it is what a DDC transaction expects anyway.
    private let queue = DispatchQueue(label: "displaypp.ddc", qos: .userInitiated)

    private static let hostAddress: UInt32 = 0x37
    private static let monitorOffset: UInt32 = 0x51

    private init() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return }
        createFn = unsafeBitCast(dlsym(handle, "IOAVServiceCreateWithService"), to: CreateFn?.self)
        writeFn = unsafeBitCast(dlsym(handle, "IOAVServiceWriteI2C"), to: WriteFn?.self)
        readFn = unsafeBitCast(dlsym(handle, "IOAVServiceReadI2C"), to: ReadFn?.self)
    }

    var isSupported: Bool { createFn != nil && writeFn != nil && readFn != nil }

    // MARK: - Service lookup

    /// Opens the AV service for the display's proxy unit. Returns `nil` when the
    /// panel is internal or has no external proxy at all.
    private func openService(unit: Int?) -> UnsafeMutableRawPointer? {
        guard let createFn, let unit else { return nil }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var seen = 0
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            let location = IORegistryEntryCreateCFProperty(service, "Location" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String
            guard location == "External" else { continue }
            if seen != unit { seen += 1; continue }
            return createFn(kCFAllocatorDefault, service)
        }
        return nil
    }

    // MARK: - Framing

    /// `Get VCP Feature` request. The `0x01` opcode is easy to forget and its
    /// absence produces a silent no-reply rather than an error.
    private func getVCPRequest(_ code: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x6E, 0x51, 0x82, 0x01, code]
        return body + [body.reduce(0, ^)]
    }

    /// `Set VCP Feature` request, 8 bytes, length nibble `0x84`.
    private func setVCPRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        let hi = UInt8(value >> 8), lo = UInt8(value & 0xFF)
        let body: [UInt8] = [0x6E, 0x51, 0x84, 0x03, code, hi, lo]
        return body + [body.reduce(0, ^)]
    }

    // MARK: - Transactions (all on `queue`)

    private func read(_ code: UInt8, service: UnsafeMutableRawPointer) -> (current: UInt16, max: UInt16)? {
        guard let writeFn, let readFn else { return nil }
        var request = getVCPRequest(code)

        for attempt in 0..<3 {
            let written = request.withUnsafeMutableBytes { buffer in
                writeFn(service, Self.hostAddress, Self.monitorOffset, buffer.baseAddress, UInt32(buffer.count))
            }
            guard written == KERN_SUCCESS else { continue }

            // DDC/CI allows the monitor 40 ms; real panels need more on the
            // first transaction after a bus wake-up.
            usleep(useconds_t(60_000 + attempt * 40_000))

            var reply = [UInt8](repeating: 0, count: 11)
            let read = reply.withUnsafeMutableBytes { buffer in
                readFn(service, Self.hostAddress, 0x00, buffer.baseAddress, UInt32(buffer.count))
            }
            guard read == KERN_SUCCESS else { continue }
            guard reply[0] == 0x6E, reply[2] == 0x02, reply[4] == code else { continue }

            let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
            let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
            guard max > 0 else { continue }
            return (current, max)
        }
        return nil
    }

    @discardableResult
    private func write(_ code: UInt8, value: UInt16, service: UnsafeMutableRawPointer) -> Bool {
        guard let writeFn else { return false }
        var request = setVCPRequest(code, value: value)
        let result = request.withUnsafeMutableBytes { buffer in
            writeFn(service, Self.hostAddress, Self.monitorOffset, buffer.baseAddress, UInt32(buffer.count))
        }
        return result == KERN_SUCCESS
    }

    // MARK: - Public API

    func probe(_ device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self, let service = self.openService(unit: device.avUnit), let reading = self.read(VCP.brightness, service: service) else {
                DispatchQueue.main.async { completion?(false) }
                return
            }
            let value = Double(reading.current) / Double(reading.max)
            DispatchQueue.main.async {
                device.brightness = value
                device.ddcAvailable = true
                completion?(true)
            }
        }
    }

    func setBrightness(_ value: Double, for device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        guard let service = openService(unit: device.avUnit) else { completion?(false); return }
        queue.async { [weak self] in
            guard let self else { return }
            // Re-read max so the 0...1 value maps onto whatever scale the panel uses.
            let max = self.read(VCP.brightness, service: service)?.max ?? 100
            let ok = self.write(VCP.brightness, value: UInt16((value * Double(max)).rounded()), service: service)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    func setContrast(_ value: Double, for device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        guard let service = openService(unit: device.avUnit) else { completion?(false); return }
        queue.async { [weak self] in
            guard let self else { return }
            let max = self.read(VCP.contrast, service: service)?.max ?? 100
            let ok = self.write(VCP.contrast, value: UInt16((value * Double(max)).rounded()), service: service)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    func readBrightness(_ device: DisplayDevice, completion: @escaping (Double?) -> Void) {
        queue.async { [weak self] in
            guard let self, let service = self.openService(unit: device.avUnit), let reading = self.read(VCP.brightness, service: service) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(Double(reading.current) / Double(reading.max)) }
        }
    }

    // MARK: - Audio, input and contrast

    /// A generic 0...1 VCP read. Kept generic so the volume, contrast and mute rows
    /// all report "no reply" the same way instead of each inventing a default.
    func read(_ code: UInt8, of device: DisplayDevice, completion: @escaping ((current: UInt16, max: UInt16)?) -> Void) {
        queue.async { [weak self] in
            guard let self, let service = self.openService(unit: device.avUnit), let reading = self.read(code, service: service) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            DispatchQueue.main.async { completion(reading) }
        }
    }

    func write(_ code: UInt8, value: Double, of device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        guard let service = openService(unit: device.avUnit) else { completion?(false); return }
        queue.async { [weak self] in
            guard let self else { return }
            let ceiling = self.read(code, service: service)?.max ?? 100
            let scaled = Swift.max(0, Swift.min(1, value))
            let ok = self.write(code, value: UInt16((scaled * Double(ceiling)).rounded()), service: service)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    func write(_ code: UInt8, raw value: UInt16, of device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        guard let service = openService(unit: device.avUnit) else { completion?(false); return }
        queue.async { [weak self] in
            guard let self else { return }
            let ok = self.write(code, value: value, service: service)
            DispatchQueue.main.async { completion?(ok) }
        }
    }

    /// Hardware volume, 0...1, as the panel itself implements it (VCP 0x62).
    func setVolume(_ value: Double, of device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        write(VCP.volume, value: value, of: device, completion: completion)
    }

    func setMuted(_ muted: Bool, of device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        write(VCP.mute, raw: muted ? 1 : 2, of: device, completion: completion)
    }

    /// Input source (VCP 0x60). The values are the MCCS ones; a panel only accepts
    /// the subset it actually has ports for, and answers nothing for the rest.
    enum InputSource: UInt16, CaseIterable {
        case vga = 0x01
        case dvi1 = 0x03
        case dvi2 = 0x04
        case hdmi1 = 0x11
        case hdmi2 = 0x12
        case displayPort1 = 0x0F
        case displayPort2 = 0x10
        case usbC = 0x13
        case component1 = 0x05

        var label: String {
            switch self {
            case .vga: return "VGA"
            case .dvi1: return "DVI-1"
            case .dvi2: return "DVI-2"
            case .hdmi1: return "HDMI-1"
            case .hdmi2: return "HDMI-2"
            case .displayPort1: return "DisplayPort-1"
            case .displayPort2: return "DisplayPort-2"
            case .usbC: return "USB-C"
            case .component1: return "Component-1"
            }
        }
    }

    func select(input: InputSource, of device: DisplayDevice, completion: ((Bool) -> Void)? = nil) {
        write(VCP.inputSource, raw: input.rawValue, of: device, completion: completion)
    }
}
