import SwiftUI
import MirrorMeshAppKit

@main
struct MirrorMeshAppEntryPoint: App {
    var body: some Scene {
        WindowGroup("MirrorMesh") {
            ContentView()
                .frame(minWidth: 960, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}
