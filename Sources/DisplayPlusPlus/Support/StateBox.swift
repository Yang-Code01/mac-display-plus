import Combine
import Foundation

/// Mutable view state for when `@State` is not available.
///
/// `@State` is a macro in the macOS 26/27 SDK and its plugin (`SwiftUIMacros`)
/// ships with Xcode, not with the Command Line Tools. `@StateObject` is still an
/// ordinary property wrapper, so a tiny reference box gives the same behaviour:
/// one instance per view identity, mutations invalidate the view.
///
/// Reads and writes are spelled `.value` instead of being transparent — noisier,
/// but it makes the reference semantics obvious at the call site.
final class StateBox<Value>: ObservableObject {
    @Published var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
