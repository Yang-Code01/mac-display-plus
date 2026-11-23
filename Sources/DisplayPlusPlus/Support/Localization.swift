import Foundation

/// Looks a UI string up in the current localization.
///
/// Keys are the English source strings, which keeps call sites readable and makes
/// a missing translation fall back to English instead of to a raw identifier. The
/// bundle ships `en.lproj` and `zh-Hans.lproj`; macOS picks one from the user's
/// language list, so nothing has to be selected in-app.
///
/// `cfBundleDevelopmentRegion` is `en`, so untranslated keys render as their
/// English text rather than as a key.
@inline(__always)
func L(_ key: String) -> String {
    NSLocalizedString(key, comment: "")
}

/// Same, for strings that take arguments (`%@`, `%d`). Kept separate so the intent
/// at the call site is obvious and a forgotten argument is easy to spot.
@inline(__always)
func L(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: NSLocalizedString(key, comment: ""), arguments: arguments)
}
