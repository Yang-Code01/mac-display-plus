import Foundation

/// The rows that open a submenu, and their order.
///
/// The order is deliberate: brightness/volume/resolution live in the block body,
/// then display-level actions, then the two switches. It is not alphabetical and not
/// grouped by type; it is the order these controls get reached for in practice, and
/// keeping it stable is most of what makes the panel learnable.
enum AppMenuSubmenu: String, CaseIterable, Hashable {
    case displayMode
    case refreshRate
    case colorMode
    case mirror
    case stream
    case pip
    case arrange
    case rotation
    case imageAdjustments
    case deviceControl
    case inputSource
    case colorProfile
    case protection
    case manageDisplay

    var title: String {
        switch self {
        case .displayMode: return L("Display Mode")
        case .refreshRate: return L("Refresh Rate")
        case .colorMode: return L("Color Mode")
        case .mirror: return L("Mirror Display")
        case .stream: return L("Stream Display")
        case .pip: return L("Picture in Picture")
        case .arrange: return L("Arrange Displays")
        case .rotation: return L("Screen Rotation")
        case .imageAdjustments: return L("Image Adjustments")
        case .deviceControl: return L("Device Control")
        case .inputSource: return L("Input Source")
        case .colorProfile: return L("Color Profile")
        case .protection: return L("Configuration Protection")
        case .manageDisplay: return L("Manage Display")
        }
    }

    /// Symbols chosen for the same silhouette as the row's subject, where such an SF
    /// Symbol exists.
    var symbol: String {
        switch self {
        case .displayMode: return "display"
        case .refreshRate: return "square.3.layers.3d"
        case .colorMode: return "drop.halffull"
        case .mirror: return "rectangle.on.rectangle"
        case .stream: return "play.rectangle"
        case .pip: return "rectangle.inset.filled.and.person.filled"
        case .arrange: return "arrow.up.left.and.arrow.down.right"
        case .rotation: return "rotate.right"
        case .imageAdjustments: return "circle.lefthalf.filled.righthalf.striped.horizontal"
        case .deviceControl: return "slider.horizontal.2.square"
        case .inputSource: return "arrow.right.square"
        case .colorProfile: return "circle.dashed"
        case .protection: return "lock.shield"
        case .manageDisplay: return "gearshape"
        }
    }
}

/// Where the panel currently is.
enum AppMenuRoute: Equatable {
    case root
    case submenu(CGDirectDisplayIDWrapper, AppMenuSubmenu)

    /// `CGDirectDisplayID` is a `UInt32` typealias, so it cannot make the enum
    /// `Equatable` on its own without it also being `Hashable` in a way SwiftUI
    /// diffing is happy with. A tiny wrapper keeps that explicit.
    struct CGDirectDisplayIDWrapper: Equatable, Hashable {
        let raw: UInt32
        init(_ id: UInt32) { self.raw = id }
    }
}
