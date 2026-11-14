import SwiftUI

/// The macOS 27 SDK also offers `@State` as a compiler macro whose plugin ships only with
/// Xcode. This alias names the property wrapper directly so the app builds with the
/// Command Line Tools alone.
typealias ViewState<Value> = SwiftUI.State<Value>
