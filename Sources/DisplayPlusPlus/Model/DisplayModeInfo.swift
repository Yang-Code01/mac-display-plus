import CoreGraphics
import Foundation

/// A display mode reduced to the fields that distinguish it to a human.
///
/// `CGDisplayMode` exposes several near-duplicate entries for the same logical
/// mode (different `ioFlags`, colour depths and tiling variants). We collapse
/// those into one row so the UI does not show the same resolution five times.
///
/// Deliberately plain values, with no stored `CGDisplayMode`. `CGDisplayMode` is
/// not toll-free bridged: the array returned by `CGDisplayCopyAllDisplayModes`
/// owns the handles, and keeping one after that array dies leaves a dangling
/// reference that fails with `kCGErrorIllegalArgument` instead of crashing.
/// Modes are re-resolved by their observable properties at switch time.
struct DisplayModeInfo: Hashable, Identifiable {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int
    let refreshRate: Double
    /// Mode number in the window server's own table, when the row only exists there.
    ///
    /// This 1080p panel can be run at 1600 × 900 points with a 3200 × 1800 framebuffer,
    /// but that mode is absent from `CGDisplayCopyAllDisplayModes` and present only in the
    /// CGS table, so a row can carry the mode number needed to apply it. `nil` means
    /// "look it up in the CoreGraphics list as before".
    var cgsModeNumber: Int32? = nil

    var id: String {
        "\(width)x\(height)@\(String(format: "%.2f", refreshRate))-\(pixelWidth)x\(pixelHeight)"
    }

    /// HiDPI means the backing store is larger than the point size, so the
    /// system renders at 2x and the user sees fewer points but sharper text.
    var isHiDPI: Bool { pixelWidth > width && pixelHeight > height }

    var aspectRatio: Double {
        height == 0 ? 0 : Double(width) / Double(height)
    }

    /// True for the panel's real pixel dimensions with no scaling.
    func isNative(for other: DisplayModeInfo?) -> Bool {
        guard let other else { return false }
        return width == other.pixelWidth && height == other.pixelHeight
    }

    static func == (lhs: DisplayModeInfo, rhs: DisplayModeInfo) -> Bool {
        lhs.width == rhs.width
            && lhs.height == rhs.height
            && lhs.pixelWidth == rhs.pixelWidth
            && lhs.pixelHeight == rhs.pixelHeight
            && abs(lhs.refreshRate - rhs.refreshRate) < 0.5
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(pixelWidth)
        hasher.combine(pixelHeight)
        hasher.combine(Int((refreshRate * 2).rounded()))
    }
}

extension DisplayModeInfo {
    /// Human label: `1440 × 900`.
    var sizeLabel: String { "\(width) × \(height)" }

    /// Pixel scale, e.g. `2x`. Derived, not guessed: it is the ratio of backing
    /// pixels to points, which is exactly what the GPU renders at.
    var scaleLabel: String {
        guard width > 0 else { return "1x" }
        let ratio = Double(pixelWidth) / Double(width)
        return ratio == ratio.rounded() ? "\(Int(ratio))x" : String(format: "%.2gx", ratio)
    }

    /// `1440 × 900 · 2x` / `1920 × 1080 · 1x`.
    var fullLabel: String { "\(sizeLabel) · \(scaleLabel)" }

    /// Identity of a *row* in the UI, not of a mode.
    ///
    /// Several refresh rates and pixel-equivalent variants collapse into one row,
    /// so refusal bookkeeping has to key on this rather than on the whole struct —
    /// otherwise a refused 400×300@50 leaves 400×300@60 in the list and the user
    /// keeps tapping a dead row.
    var rowKey: String { "\(width)x\(height)-\(isHiDPI)" }
}
