import SwiftUI
import AppKit
import MirrorMeshAppKit

/// macOS app entry point. Built as `MirrorMesh.app` via `MirrorMesh.xcodeproj` (xcodegen).
/// Follows Apple's canonical SwiftUI macOS App template: single WindowGroup + a `.commands`
/// modifier that customizes the menu bar.
@main
struct MirrorMeshAppEntryPoint: App {
    @StateObject private var viewModel = PipelineViewModel()

    var body: some Scene {
        WindowGroup("MirrorMesh") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 980, minHeight: 600)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MirrorMesh") { showAboutPanel() }
            }

            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    if viewModel.running { viewModel.stop() }
                    viewModel.consent = nil
                }
                .keyboardShortcut("n")

                Button("Reveal Sessions Folder") { revealSessionsFolder() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Open Project Memory Bank…") { openMemoryBank() }
            }

            CommandGroup(after: .toolbar) {
                Divider()
                // Why: `settings` is `let` on PipelineViewModel; SwiftUI's `$viewModel.settings.x`
                // resolver tries to assign through the parent. Build custom bindings instead.
                Toggle("Show Landmarks Overlay", isOn: Binding(
                    get: { viewModel.settings.showLandmarks },
                    set: { viewModel.settings.showLandmarks = $0 }
                ))
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Toggle("Show Avatar Mask", isOn: Binding(
                    get: { viewModel.settings.showAvatarMask },
                    set: { viewModel.settings.showAvatarMask = $0 }
                ))
                .keyboardShortcut("a", modifiers: [.command, .shift])
            }

            CommandMenu("Pipeline") {
                Button("Toggle Watermark Visibility") {
                    viewModel.settings.watermarkVisible.toggle()
                }
                .disabled(viewModel.settings.watermarkLockedInRelease)
                .keyboardShortcut("w", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .help) {
                Button("MirrorMesh Documentation") { openDocs() }
                Button("Project License (AGPL-3.0)") { openLicense() }
                Button("Research Notice") { openNotice() }
            }
        }
    }

    // MARK: - Menu actions

    private func showAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "MirrorMesh",
            .applicationVersion: "1.0.0-dev",
            .credits: NSAttributedString(
                string: "Open realtime telepresence research for Apple Silicon.\n\n"
                      + "Local-only inference. Watermarked by default. Consent-gated by design.\n\n"
                      + "AGPL-3.0-only research project. No commercial use.",
                attributes: [.foregroundColor: NSColor.labelColor]
            ),
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"):
                "© 2026 Michael Sitarzewski. AGPL-3.0 — see LICENSE and NOTICE.md."
        ])
    }

    private func revealSessionsFolder() {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ) else { return }
        let dir = appSupport.appendingPathComponent("MirrorMesh/sessions", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([dir])
    }

    private func openMemoryBank() {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/memory-bank",
            "/Users/michael/Clean/mirror-mesh/memory-bank",
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }

    private func openDocs() {
        if let url = URL(string: "https://github.com/mirrormesh/mirror-mesh/tree/main/docs") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openLicense() {
        if let url = URL(string: "https://www.gnu.org/licenses/agpl-3.0.html") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openNotice() {
        let candidates = [
            FileManager.default.currentDirectoryPath + "/NOTICE.md",
            "/Users/michael/Clean/mirror-mesh/NOTICE.md",
        ]
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: url.path) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}
