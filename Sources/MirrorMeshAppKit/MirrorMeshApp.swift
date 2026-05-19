import SwiftUI

/// Top-level `App` for the macOS shell. Defined here as library code so the SwiftPM build can
/// type-check the entire UI tree on Command Line Tools; the future Xcode `app/` wrapper will
/// simply add `@main` at link time via its own target settings.
public struct MirrorMeshApp: App {
    public init() {}

    public var body: some Scene {
        WindowGroup("MirrorMesh") {
            ContentView()
        }
        // Why: macOS 14 default window sizing is too small for the three-pane layout.
        .defaultSize(width: 1100, height: 680)
    }
}
