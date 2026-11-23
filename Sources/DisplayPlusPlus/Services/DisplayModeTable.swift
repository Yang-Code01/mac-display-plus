import CoreGraphics
import Foundation

/// The window server's own display mode table.
///
/// Why this exists: `CGDisplayCopyAllDisplayModes` is *not* the whole list. This 1080p
/// panel can be driven at `1600 × 900` with a `3200 × 1800` framebuffer — real HiDPI,
/// same desktop size, twice the pixels — and that mode does not appear in the
/// CoreGraphics list at all. It is only in the SkyLight table:
///
/// ```
/// display 2: CG unique modes = 64, CGS modes = 97
/// mode 48: flags=0x200001 1600x900  rowBytes=12800  (12800 / 4 = 3200 px wide)  @60 Hz
/// mode 49: flags=0x200001 1600x900  rowBytes=12800  @50 Hz
/// mode 31: flags=0x000001 1600x900  rowBytes= 6400  (1600 px wide)             @60 Hz
/// ```
///
/// Applying mode 48 through `CGSConfigureDisplayMode` inside a display configuration
/// transaction produced `pix=3200x1800` (verified by `--hidpi-test`), and applying
/// mode 31 undid it. So the mechanism is: enumerate the CGS table, decode
/// width/height/rowBytes/flags, and apply by mode number.
///
/// The struct below is a guess at names, not at the wire layout — the layout was read off
/// the bytes (word 0 is the mode number, 2/3 are the point width/height, 5 is rowBytes,
/// 9 is whole-hertz refresh), and the decode is verified by matching every mode against
/// what CoreGraphics reports for the same display.
enum DisplayModeTable {
    /// One entry of the CGS table, already resolved to what a human cares about.
    struct Mode: Hashable {
        let number: Int32
        let flags: UInt32
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double
        let bitsPerPixel: Int

        /// HiDPI as the window server means it: the backing store is larger than the
        /// point size. This is the same test CoreGraphics uses for `pixelWidth > width`.
        var isHiDPI: Bool { pixelWidth > width }

        var info: DisplayModeInfo {
            DisplayModeInfo(
                width: width,
                height: height,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                refreshRate: refreshRate.rounded(),
                cgsModeNumber: number
            )
        }
    }

    private typealias CountFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Int32>) -> Int32
    private typealias DescFn = @convention(c) (CGDirectDisplayID, Int32, UnsafeMutableRawPointer, Int32) -> Int32
    private typealias ApplyFn = @convention(c) (CGDisplayConfigRef?, CGDirectDisplayID, Int32) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static let countFn: CountFn? = handle.flatMap { dlsym($0, "CGSGetNumberOfDisplayModes") }.map {
        unsafeBitCast($0, to: CountFn.self)
    }
    private static let descFn: DescFn? = handle.flatMap { dlsym($0, "CGSGetDisplayModeDescriptionOfLength") }.map {
        unsafeBitCast($0, to: DescFn.self)
    }
    private static let applyFn: ApplyFn? = handle.flatMap { dlsym($0, "CGSConfigureDisplayMode") }.map {
        unsafeBitCast($0, to: ApplyFn.self)
    }

    static var isAvailable: Bool { countFn != nil && descFn != nil && applyFn != nil }

    /// The whole table for a display, or an empty array when SkyLight cannot be reached.
    static func modes(for display: CGDirectDisplayID) -> [Mode] {
        guard let countFn, let descFn else { return [] }
        var count: Int32 = 0
        guard countFn(display, &count) == 0, count > 0 else { return [] }

        var out: [Mode] = []
        var buffer = [UInt8](repeating: 0, count: 128)
        for index in 0..<Int(count) {
            let status = buffer.withUnsafeMutableBytes { descFn(display, Int32(index), $0.baseAddress!, 128) }
            guard status == 0 else { continue }
            let mode: Mode = buffer.withUnsafeBytes { raw in
                func word(_ i: Int) -> UInt32 { raw.load(fromByteOffset: i * 4, as: UInt32.self) }
                let bitsPerPixel = Int(word(6))
                let rowBytes = Int(word(5))
                let bytesPerPixel = max(1, bitsPerPixel / 8)
                let width = Int(word(2))
                let height = Int(word(3))
                let pixelWidth = rowBytes / bytesPerPixel
                // A 2x mode has twice the rows of its point height; rowBytes is the only
                // place the pixel width survives in this struct.
                let pixelHeight = bytesPerPixel > 0 ? height * max(1, pixelWidth / max(1, width)) : height
                return Mode(
                    number: Int32(bitPattern: word(0)),
                    flags: word(1),
                    width: width,
                    height: height,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    refreshRate: Double(word(9)),
                    bitsPerPixel: bitsPerPixel
                )
            }
            guard mode.width > 0, mode.height > 0, mode.pixelWidth > 0 else { continue }
            out.append(mode)
        }
        return out
    }

    /// HiDPI twins of a point size: same `width × height`, larger backing store.
    ///
    /// This is precisely what the menu row "High Resolution (HiDPI)" means, and
    /// precisely what the CoreGraphics list does not contain for most external panels.
    static func hiDPITwins(of display: CGDirectDisplayID, width: Int, height: Int) -> [Mode] {
        modes(for: display).filter { $0.width == width && $0.height == height && $0.isHiDPI }
    }

    /// The 1x mode of the same point size, used when turning HiDPI back off.
    static func lowResTwin(of display: CGDirectDisplayID, width: Int, height: Int) -> [Mode] {
        modes(for: display).filter { $0.width == width && $0.height == height && !$0.isHiDPI }
    }

    /// Applies a CGS mode number inside a display configuration transaction.
    ///
    /// The arrangement pins ride along for the same reason as in `DisplayManager.apply`:
    /// a mode change alone lets the window server reflow the layout, and a separate
    /// origin transaction is silently dropped.
    @discardableResult
    static func apply(modeNumber: Int32, to display: CGDirectDisplayID, pinning arrangement: [CGDirectDisplayID: CGPoint]) -> Bool {
        guard let applyFn else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        let status = applyFn(config, display, modeNumber)
        for (id, origin) in arrangement where id != display {
            _ = CGConfigureDisplayOrigin(config, id, Int32(origin.x.rounded()), Int32(origin.y.rounded()))
        }
        guard status == 0, CGCompleteDisplayConfiguration(config, .permanently) == .success else {
            CGCompleteDisplayConfiguration(config, .forSession)
            return false
        }
        return true
    }
}
