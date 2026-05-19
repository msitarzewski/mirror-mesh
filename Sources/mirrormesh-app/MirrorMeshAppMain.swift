import AppKit
import SwiftUI
import MirrorMeshAppKit

// Why: SwiftPM executables can't use `@main App` and get a full NSApplication menu/window;
// drive NSApplication.shared directly per M12 spec (memory-bank/release/v0.2.0/M12-app-executable.md).
//
// Info.plist limitation (v0.2.0): SwiftPM does NOT bundle Sources/mirrormesh-app/Info.plist
// into the produced binary, so macOS won't read NSCameraUsageDescription from it for the
// permission prompt. The binary still runs; if live capture is engaged the first time, the
// user may need to grant Camera access via System Settings → Privacy & Security → Camera for
// the parent process (Terminal/Xcode). A real `.xcodeproj`/`.app` bundle is v0.3.0+ scope.

/// AppDelegate hosts the SwiftUI `ContentView` from `MirrorMeshAppKit` inside an `NSWindow`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let hosting = NSHostingController(rootView: ContentView())

        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = "MirrorMesh"
        window.contentViewController = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)

        // Why: SPM executable defaults to background; promote to foreground so the window is visible.
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - Entrypoint
//
// Wrapped in a `@main` struct so Xcode's parser accepts the file. Per ADR-0013, executable
// targets that use `@main` must NOT name their entry file `main.swift`. Conversely, a non-
// `main.swift` file in an executable target must NOT contain top-level executable code unless
// it's inside a `@main` type. This struct satisfies both halves.

@main
struct MirrorMeshAppEntry {
    static func main() {
        let smokeTest = CommandLine.arguments.contains("--smoke-test")

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)

        if smokeTest {
            // Why: CI launch-smoke — auto-exit cleanly after ~2 s so headless runners don't hang.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                NSApp.terminate(nil)
            }
        }

        // Hold the delegate alive until app.run() returns. Swift would otherwise free it after
        // setting it on `app.delegate` (NSApplication's delegate is a weak reference).
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
