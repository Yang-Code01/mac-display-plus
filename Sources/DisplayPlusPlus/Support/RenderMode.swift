import AppKit
import SwiftUI

/// Whether the UI is being drawn without a window server.
///
/// `NSGlassEffectView` only composites against a real backdrop, so in an
/// offscreen render it comes out empty. Rather than give up on visual checks, the
/// glass block falls back to a material-styled rounded rect that has the same
/// geometry, tint and corner radius — everything except the live backdrop blur,
/// which is the one thing an offscreen image could not show anyway.
enum RenderMode {
    nonisolated(unsafe) static var isOffscreen = false
}
