import AppKit
import CoreGraphics
import Foundation

/// One physical (or virtual) display plus everything the UI needs about it.
///
/// This is the single place that knows how CoreGraphics ids line up with
/// `NSScreen`s and with the IOKit AV service used for DDC.
final class DisplayDevice: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    let isMain: Bool
    /// `DCPAVServiceProxy` unit index for external displays; `nil` for internal.
    let avUnit: Int?

    /// Every distinct mode the display offers, HiDPI included, sorted for display.
    var modes: [DisplayModeInfo] = []
    var currentMode: DisplayModeInfo?

    /// Best-known hardware brightness, 0...1. `nil` when DDC has never answered.
    var brightness: Double?
    /// Hardware contrast, 0...1.
    var contrast: Double?
    /// Modes macOS advertises but refuses to apply. `CGDisplayCopyAllDisplayModes`
    /// with `kCGDisplayShowDuplicateLowResolutionModes` synthesises HiDPI entries
    /// from low-resolution 4:3 modes that the panel cannot actually run: they come
    /// back with the valid flag set and then fail with `kCGErrorIllegalArgument`.
    /// Remembering them keeps a dead row out of the list after the first attempt.
    var refusedModes: Set<String> = []

    /// True once DDC answered a read successfully.
    var ddcAvailable: Bool = false
    /// Set while a DDC transaction is in flight so the UI can show progress.
    var ddcPending: Bool = false

    init(id: CGDirectDisplayID, name: String, isBuiltIn: Bool, isMain: Bool, avUnit: Int?) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.isMain = isMain
        self.avUnit = avUnit
    }

    static func == (lhs: DisplayDevice, rhs: DisplayDevice) -> Bool { lhs.id == rhs.id }

    // MARK: - Derived state for the panel

    /// The mode list with one row per logical resolution, HiDPI kept because it
    /// is the whole point of the app, but duplicates within a class dropped.
    var resolutionChoices: [DisplayModeInfo] {
        var seen = Set<String>()
        return modes.filter { mode in
            guard !refusedModes.contains(mode.rowKey) else { return false }
            guard matchesNativeAspect(mode) else { return false }
            let key = mode.rowKey
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    /// The size dimension only: one row per desktop size, for the slider and for the
    /// keyboard step shortcuts.
    ///
    /// HiDPI is a dimension *of* a size, not a size of its own. Walking
    /// `resolutionChoices` (which keeps both `1600 × 900 · 1x` and `1600 × 900 · 2x`)
    /// made toggling HiDPI move the slider one step for something the user reads as
    /// "make the text sharper" — it looked like a resolution change. Each size is
    /// therefore represented by the variant that matches the current scale class, so
    /// the knob sits still while sharpness toggles, and dragging walks sizes while
    /// keeping the current sharpness.
    var sliderChoices: [DisplayModeInfo] {
        let wantHiDPI = currentMode?.isHiDPI ?? false
        var seen = Set<String>()
        var out: [DisplayModeInfo] = []
        for mode in resolutionChoices {
            let key = "\(mode.width)x\(mode.height)"
            guard seen.insert(key).inserted else { continue }
            let sameSize = resolutionChoices.filter { $0.width == mode.width && $0.height == mode.height }
            out.append(sameSize.first { $0.isHiDPI == wantHiDPI } ?? mode)
        }
        return out
    }

    /// Modes the panel will actually switch to, restricted to its own aspect ratio.
    var usableModes: [DisplayModeInfo] {
        modes.filter { !refusedModes.contains($0.rowKey) && matchesNativeAspect($0) }
    }

    /// Every mode that has not been proven unsettable, including stretched shapes.
    var allSelectableModes: [DisplayModeInfo] {
        modes.filter { !refusedModes.contains($0.rowKey) }
    }

    var refreshChoices: [Double] {
        Array(Set(modes.map { ($0.refreshRate * 100).rounded() / 100 })).sorted(by: >)
    }

    /// `1440 × 900 · 2x`. Reports the real pixel ratio instead of a percentage:
    /// macOS has no public "default mode" to measure a percentage against, and a
    /// made-up denominator would be worse than no number.
    var resolutionLabel: String {
        currentMode?.fullLabel ?? "—"
    }

    /// Widest pixel dimension the panel physically has.
    var nativeWidth: Int { modes.map(\.pixelWidth).max() ?? currentMode?.width ?? 0 }

    /// Aspect ratio of the panel's largest mode, used to tell which modes can be
    /// shown without stretching.
    var nativeAspect: Double {
        // The mode with the most backing pixels is the panel's own geometry; HiDPI
        // variants share it, so this is stable across 1x and 2x.
        guard let native = modes.max(by: { $0.pixelWidth < $1.pixelWidth }), native.height > 0 else {
            return currentMode?.aspectRatio ?? 0
        }
        return Double(native.pixelWidth) / Double(native.pixelHeight)
    }

    /// Whether a mode matches the panel's shape closely enough to fill it without
    /// distortion.
    ///
    /// Display mode lists include 4:3, 5:4 and 16:10 entries alongside the panel's own
    /// geometry. A monitor handed a signal of the wrong shape does not letterbox it —
    /// it stretches to fill, so circles become ellipses. This is what "the image is
    /// stretched" turns out to be. Filtering the mode menu on the native aspect ratio
    /// is what avoids it, so a 16:9 panel only lists 16:9 modes.
    func matchesNativeAspect(_ mode: DisplayModeInfo) -> Bool {
        let native = nativeAspect
        guard native > 0, mode.height > 0 else { return false }
        let aspect = mode.aspectRatio
        return abs(aspect - native) / native < 0.01
    }

    var isHiDPIActive: Bool { currentMode?.isHiDPI ?? false }

    var connectionLabel: String {
        if isBuiltIn { return "Built-in" }
        return "External"
    }

    /// Position on the slider, 0...1, derived from the current width across the
    /// range the panel supports. Used so the slider is a real control, not a
    /// decorative one.
    var resolutionSliderValue: Double {
        let choices = sliderChoices
        guard let currentMode, !choices.isEmpty else { return 0 }
        guard let index = choices.firstIndex(where: {
            $0.width == currentMode.width && $0.height == currentMode.height && $0.isHiDPI == currentMode.isHiDPI
        }) else { return 0 }
        return Double(index) / Double(max(1, choices.count - 1))
    }
}
