// swift-tools-version:5.10
import PackageDescription

// MARK: - Target dependencies
//
// Tests use Swift Testing (`import Testing`) and require an Xcode toolchain.
// Either run `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer` once,
// or prefix swift invocations with
//   `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
// `mirrormesh-selftest` is retained as a CLT-friendly smoke binary for environments
// without Xcode. See `memory-bank/decisions.md#ADR-0012`.
//
// MirrorMeshStream + mirrormesh-stream pull in the stasel/WebRTC binary (~30 MB).
// They are isolated targets — the bench/app/selftest executables do not link them,
// so a default `swift build` still works if the WebRTC package fails to resolve
// only when those targets are explicitly built (e.g. `swift build --target MirrorMeshStream`).
// See `docs/dependencies.md`.

let package = Package(
    name: "MirrorMesh",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MirrorMeshCore", targets: ["MirrorMeshCore"]),
        .library(name: "MirrorMeshCapture", targets: ["MirrorMeshCapture"]),
        .library(name: "MirrorMeshVision", targets: ["MirrorMeshVision"]),
        .library(name: "MirrorMeshSolver", targets: ["MirrorMeshSolver"]),
        .library(name: "MirrorMeshRender", targets: ["MirrorMeshRender"]),
        .library(name: "MirrorMeshWatermark", targets: ["MirrorMeshWatermark"]),
        .library(name: "MirrorMeshRecorder", targets: ["MirrorMeshRecorder"]),
        .library(name: "MirrorMeshOutput", targets: ["MirrorMeshOutput"]),
        .library(name: "MirrorMeshVirtualCamera", targets: ["MirrorMeshVirtualCamera"]),
        .library(name: "MirrorMeshMediaPipe", targets: ["MirrorMeshMediaPipe"]),
        .library(name: "MirrorMeshAppKit", targets: ["MirrorMeshAppKit"]),
        .library(name: "MirrorMeshStream", targets: ["MirrorMeshStream"]),
        .library(name: "MirrorMeshVoice", targets: ["MirrorMeshVoice"]),
        .executable(name: "mirrormesh-bench", targets: ["mirrormesh-bench"]),
        .executable(name: "mirrormesh-verify", targets: ["mirrormesh-verify"]),
        .executable(name: "mirrormesh-selftest", targets: ["mirrormesh-selftest"]),
        .executable(name: "mirrormesh-app", targets: ["mirrormesh-app"]),
        .executable(name: "mirrormesh-fixture-gen", targets: ["mirrormesh-fixture-gen"]),
        .executable(name: "mirrormesh-stream", targets: ["mirrormesh-stream"]),
        .executable(name: "mirrormesh-listen", targets: ["mirrormesh-listen"]),
    ],
    dependencies: [
        // Pre-built libwebrtc binary Swift package (Apache 2.0). Opt-in: only MirrorMeshStream
        // + mirrormesh-stream + MirrorMeshStreamTests resolve this.
        .package(url: "https://github.com/stasel/WebRTC.git", from: "138.0.0"),
    ],
    targets: [
        .target(
            name: "MirrorMeshCore",
            path: "Sources/MirrorMeshCore"
        ),
        .target(
            name: "MirrorMeshCapture",
            dependencies: ["MirrorMeshCore"],
            path: "Sources/MirrorMeshCapture"
        ),
        .target(
            name: "MirrorMeshVision",
            dependencies: ["MirrorMeshCore", "MirrorMeshCapture"],
            path: "Sources/MirrorMeshVision"
        ),
        .target(
            name: "MirrorMeshSolver",
            dependencies: ["MirrorMeshCore", "MirrorMeshVision"],
            path: "Sources/MirrorMeshSolver",
            // Why: ship the trained CoreML weights so Bundle.module finds them in any consumer
            // (including the .app bundle). The file under Resources/ is a build-time copy; the
            // canonical artifact lives at models/blendshape_solver_v1.mlpackage and is regenerated
            // by models/training/blendshape_solver.py. R5 provenance applies to both copies.
            resources: [.copy("Resources/blendshape_solver_v1.mlpackage")]
        ),
        .target(
            name: "MirrorMeshRender",
            dependencies: [
                "MirrorMeshCore",
                "MirrorMeshCapture",
                "MirrorMeshVision",
                "MirrorMeshSolver",
            ],
            path: "Sources/MirrorMeshRender",
            // .copy (not .process) — MetalContext reads .metal source at runtime and calls
            // device.makeLibrary(source:). `.process` would compile the .metal files into a
            // .metallib via Xcode's metal compiler and the raw source disappears from the
            // bundle, breaking the runtime read. CLI swift build is more lenient.
            resources: [.copy("Shaders")]
        ),
        .target(
            name: "MirrorMeshWatermark",
            dependencies: ["MirrorMeshCore", "MirrorMeshRender"],
            path: "Sources/MirrorMeshWatermark"
        ),
        .target(
            name: "MirrorMeshRecorder",
            dependencies: [
                "MirrorMeshCore",
                "MirrorMeshWatermark",
            ],
            path: "Sources/MirrorMeshRecorder"
        ),
        .target(
            name: "MirrorMeshOutput",
            dependencies: [
                "MirrorMeshCore",
                "MirrorMeshRender",
                "MirrorMeshWatermark",
                "MirrorMeshRecorder",
                "MirrorMeshVirtualCamera",
            ],
            path: "Sources/MirrorMeshOutput"
        ),
        .target(
            name: "MirrorMeshVirtualCamera",
            dependencies: ["MirrorMeshCore"],
            path: "Sources/MirrorMeshVirtualCamera"
        ),
        // Why isolated: a real MediaPipe Tasks Swift integration drags in a ~12 MB XCFramework.
        // The current implementation (M26) is a Vision-fallback stub so a default `swift build`
        // works without that binary; the protocol + dispatch logic are in place for a follow-up
        // that vendors the real binary. See `docs/landmark-comparison.md`.
        .target(
            name: "MirrorMeshMediaPipe",
            dependencies: ["MirrorMeshCore", "MirrorMeshVision"],
            path: "Sources/MirrorMeshMediaPipe"
        ),
        .target(
            name: "MirrorMeshAppKit",
            dependencies: [
                "MirrorMeshCore",
                "MirrorMeshCapture",
                "MirrorMeshVision",
                "MirrorMeshSolver",
                "MirrorMeshRender",
                "MirrorMeshWatermark",
                "MirrorMeshOutput",
            ],
            path: "Sources/MirrorMeshAppKit"
        ),
        .executableTarget(
            name: "mirrormesh-bench",
            dependencies: [
                "MirrorMeshCore",
                "MirrorMeshCapture",
                "MirrorMeshVision",
                "MirrorMeshSolver",
                "MirrorMeshRender",
                "MirrorMeshWatermark",
                "MirrorMeshOutput",
                "MirrorMeshMediaPipe",
            ],
            path: "Sources/mirrormesh-bench"
        ),
        .executableTarget(
            name: "mirrormesh-verify",
            dependencies: ["MirrorMeshCore", "MirrorMeshWatermark"],
            path: "Sources/mirrormesh-verify"
        ),
        .executableTarget(
            name: "mirrormesh-selftest",
            dependencies: [
                "MirrorMeshCore",
                "MirrorMeshCapture",
                "MirrorMeshVision",
                "MirrorMeshSolver",
                "MirrorMeshRender",
                "MirrorMeshWatermark",
                "MirrorMeshOutput",
            ],
            path: "Sources/mirrormesh-selftest"
        ),
        .executableTarget(
            name: "mirrormesh-fixture-gen",
            dependencies: [],
            path: "Sources/mirrormesh-fixture-gen"
        ),
        .executableTarget(
            name: "mirrormesh-app",
            dependencies: ["MirrorMeshAppKit"],
            path: "Sources/mirrormesh-app",
            // Why: SPM forbids a top-level Info.plist as a resource. The file is informational
            // for v0.2.0 (documenting usage strings + bundle id); a real .app bundle in v0.3.0
            // will consume it. Excluded from build to avoid SPM's restriction.
            exclude: ["Info.plist"]
        ),

        // ── Test targets (require Xcode toolchain) ──────────────────────
        .testTarget(
            name: "MirrorMeshCoreTests",
            dependencies: ["MirrorMeshCore"],
            path: "Tests/MirrorMeshCoreTests"
        ),
        .testTarget(
            name: "MirrorMeshCaptureTests",
            dependencies: ["MirrorMeshCapture"],
            path: "Tests/MirrorMeshCaptureTests"
        ),
        .testTarget(
            name: "MirrorMeshVisionTests",
            dependencies: ["MirrorMeshVision"],
            path: "Tests/MirrorMeshVisionTests"
        ),
        .testTarget(
            name: "MirrorMeshSolverTests",
            dependencies: ["MirrorMeshSolver"],
            path: "Tests/MirrorMeshSolverTests"
        ),
        .testTarget(
            name: "MirrorMeshRenderTests",
            dependencies: ["MirrorMeshRender"],
            path: "Tests/MirrorMeshRenderTests"
        ),
        .testTarget(
            name: "MirrorMeshWatermarkTests",
            dependencies: ["MirrorMeshWatermark"],
            path: "Tests/MirrorMeshWatermarkTests"
        ),
        .testTarget(
            name: "MirrorMeshOutputTests",
            dependencies: ["MirrorMeshOutput"],
            path: "Tests/MirrorMeshOutputTests"
        ),
        .testTarget(
            name: "MirrorMeshRecorderTests",
            dependencies: ["MirrorMeshRecorder", "MirrorMeshWatermark"],
            path: "Tests/MirrorMeshRecorderTests"
        ),
        .testTarget(
            name: "MirrorMeshIntegrationTests",
            dependencies: ["MirrorMeshOutput", "MirrorMeshWatermark"],
            path: "Tests/MirrorMeshIntegrationTests"
        ),
        .testTarget(
            name: "MirrorMeshVirtualCameraTests",
            dependencies: ["MirrorMeshVirtualCamera", "MirrorMeshCore", "MirrorMeshWatermark"],
            path: "Tests/MirrorMeshVirtualCameraTests"
        ),
        .testTarget(
            name: "MirrorMeshMediaPipeTests",
            dependencies: ["MirrorMeshMediaPipe", "MirrorMeshVision", "MirrorMeshCapture", "MirrorMeshCore"],
            path: "Tests/MirrorMeshMediaPipeTests"
        ),

        // ── WebRTC streaming (opt-in; ~30 MB binary dep) ────────────────
        .target(
            name: "MirrorMeshStream",
            dependencies: [
                "MirrorMeshCore",
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/MirrorMeshStream"
        ),
        .executableTarget(
            name: "mirrormesh-stream",
            dependencies: [
                "MirrorMeshCore",
                "MirrorMeshStream",
            ],
            path: "Sources/mirrormesh-stream"
        ),
        .testTarget(
            name: "MirrorMeshStreamTests",
            dependencies: ["MirrorMeshStream", "MirrorMeshCore"],
            path: "Tests/MirrorMeshStreamTests"
        ),

        // ── Voice pipeline (M28) ────────────────────────────────────────
        // Why isolated: the v0.3.0 build ships a mocked Whisper backend (see
        // docs/voice-pipeline.md). The real whisper.cpp link is a future drop-in
        // — keeping the module separate means the bench/selftest binaries don't
        // gain an audio dependency until voice is opt-in everywhere.
        .target(
            name: "MirrorMeshVoice",
            dependencies: ["MirrorMeshCore"],
            path: "Sources/MirrorMeshVoice"
        ),
        .executableTarget(
            name: "mirrormesh-listen",
            dependencies: ["MirrorMeshCore", "MirrorMeshVoice"],
            path: "Sources/mirrormesh-listen"
        ),
        .testTarget(
            name: "MirrorMeshVoiceTests",
            dependencies: ["MirrorMeshVoice", "MirrorMeshCore"],
            path: "Tests/MirrorMeshVoiceTests"
        ),
    ]
)
