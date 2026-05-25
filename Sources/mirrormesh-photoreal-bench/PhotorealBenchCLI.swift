import Foundation
import CryptoKit
import CoreVideo
import CoreImage
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import MirrorMeshCore
import MirrorMeshWatermark
import MirrorMeshReenact

// Phase 1 of the photoreal v2 plan: a CLI that runs PhotorealBackend.reenact(driver:)
// standalone on two PNGs (a source and a driving frame) and writes the output to a PNG
// path. Lets us produce a Swift-side artifact that can be diff'd byte-for-byte (or
// visually side-by-side) against the upstream LivePortrait Python reference on the same
// inputs. The point is to settle the inference-correctness question *outside* the UI
// pipeline, where every degree-of-freedom (camera framing, lighting, composite alpha,
// render pass interaction, watermark, viewport scaling) is removed.
//
// See:
//   - memory project_photoreal_v2_plan.md (resumption checklist, Phase 1)
//   - memory feedback_ml_integration_validation.md (the lesson this CLI exists to enforce)
//   - memory-bank/tasks/2026-05/260520_photoreal-paused.md (the hypotheses this CLI helps bisect)
//
// Usage:
//   swift run mirrormesh-photoreal-bench \
//       --source <source.png> \
//       --driver <driver.png> \
//       --out <output.png> \
//       [--kind liveportrait|fomm] \
//       [--models-dir <dir>] \
//       [--quiet]
//
// The CLI mints a fresh self-as-source ConsentedIdentity in-process (signed with a fresh
// Ed25519 keypair, scope "v1.0+"), so no .mmid file needs to exist on disk to run the
// inference path. The signed identity satisfies PhotorealBackend's R12 gate exactly as a
// real bundle would.

@main
struct PhotorealBenchCLI {

    static func main() async {
        let args = CommandLine.arguments

        if args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(0)
        }

        let parsed: Args
        do {
            parsed = try Args(args: args)
        } catch let e as ArgError {
            FileHandle.standardError.write(Data("ERROR: \(e.message)\n\n".utf8))
            printUsage()
            exit(2)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(2)
        }

        do {
            try await run(parsed)
            exit(0)
        } catch let e as BenchError {
            FileHandle.standardError.write(Data("ERROR: \(e.message)\n".utf8))
            exit(e.exitCode)
        } catch {
            FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
            exit(10)
        }
    }

    // MARK: - Run

    static func run(_ args: Args) async throws {
        let t0 = MirrorMeshCore.hostTimeNs()

        // (1) Read source PNG.
        let sourcePNG: Data
        do {
            sourcePNG = try Data(contentsOf: args.sourceURL)
        } catch {
            throw BenchError(message: "cannot read --source at \(args.sourceURL.path): \(error)", exitCode: 3)
        }
        guard !sourcePNG.isEmpty else {
            throw BenchError(message: "--source file is empty", exitCode: 3)
        }

        // (2) Mint a self-as-source ConsentedIdentity in-process. Same canonical-message
        //     construction as Sources/mirrormesh-consent/ConsentCLI.swift to satisfy
        //     ConsentedIdentityVerifier.verify on the runtime side. Scope "v1.0+" matches
        //     the current MirrorMeshCore.version baseline.
        let identity = try mintIdentity(pngBytes: sourcePNG, displayName: "photoreal-bench")
        if !args.quiet {
            print("identity:       \(identity.identity_id) (\(identity.scheme.rawValue))")
        }

        // (3) Construct PhotorealBackend. This does its own ConsentedIdentityVerifier.verify
        //     gate, loads + compiles the four .mlpackage files, runs prepareSource on the
        //     source PNG (caching feature_3d + transformed kp_source for LP, or sourceImage
        //     + source keypoints for FOMM). On exit from init the backend is ready to drive.
        let backend: PhotorealBackend
        do {
            backend = try await PhotorealBackend(
                identity: identity,
                pngBytes: sourcePNG,
                runtimeVersion: MirrorMeshCore.version,
                modelsDir: args.modelsDir,
                kind: args.kind
            )
        } catch let e as PhotorealBackend.LoadError {
            throw BenchError(message: "PhotorealBackend init failed: \(e.description)", exitCode: 4)
        } catch {
            throw BenchError(message: "PhotorealBackend init failed: \(error)", exitCode: 4)
        }
        let tAfterInit = MirrorMeshCore.hostTimeNs()
        if !args.quiet {
            print("prepareSource:  \(formatMs(tAfterInit - t0))")
        }

        // (4) Read driver PNG -> CVPixelBuffer (BGRA, IOSurface-backed). The same flavor
        //     the live pipeline feeds in via camera capture. We don't pre-crop here —
        //     PhotorealBackend.reenact does its own square center-crop + 256x256 resize
        //     through PixelBufferConversion.makeMLInput.
        let driverPNG: Data
        do {
            driverPNG = try Data(contentsOf: args.driverURL)
        } catch {
            throw BenchError(message: "cannot read --driver at \(args.driverURL.path): \(error)", exitCode: 3)
        }
        let driverBuffer = try makePixelBuffer(fromPNG: driverPNG)

        // (5) Run the per-frame forward. When --dump-tensors is set, PhotorealBackend
        //     writes each submodel boundary's MLMultiArray to <dir>/<name>.bin (raw
        //     float32) + <dir>/<name>.json (shape + dtype). This is the Phase 2 v2 plan
        //     gating tool: every MPSGraph submodel port has to numerically match the
        //     CoreML reference on the same input, and that diff lives in these files.
        let output: CVPixelBuffer
        do {
            output = try await backend.reenact(
                driver: driverBuffer,
                tensorDumpDir: args.tensorDumpDir
            )
        } catch let e as PhotorealBackend.LoadError {
            throw BenchError(message: "reenact failed: \(e.description)", exitCode: 5)
        } catch {
            throw BenchError(message: "reenact failed: \(error)", exitCode: 5)
        }
        let tAfterReenact = MirrorMeshCore.hostTimeNs()
        if !args.quiet {
            print("reenact:        \(formatMs(tAfterReenact - tAfterInit))")
            if let dumpDir = args.tensorDumpDir {
                print("tensor dump:    \(dumpDir.path)")
            }
        }

        // (6) Write output as PNG.
        try writePNG(pixelBuffer: output, to: args.outURL)
        let tAfterWrite = MirrorMeshCore.hostTimeNs()
        if !args.quiet {
            print("write:          \(formatMs(tAfterWrite - tAfterReenact))")
            print("output:         \(args.outURL.path)")
            print("total:          \(formatMs(tAfterWrite - t0))")
        } else {
            print(args.outURL.path)
        }
    }

    // MARK: - Identity minting (in-process self-as-source)

    /// Build + sign a fresh self-as-source ConsentedIdentity that binds the supplied PNG.
    /// Same canonical message layout as `mirrormesh-consent` (canonical header JSON with
    /// signature cleared, concatenated with PNG bytes), so the runtime's
    /// `ConsentedIdentityVerifier.verify` succeeds without any disk I/O. The Ed25519 key
    /// is discarded after signing — the bench CLI's only output of interest is the
    /// rendered PNG.
    static func mintIdentity(pngBytes: Data, displayName: String) throws -> ConsentedIdentity {
        let pngHash = SHA256.hash(data: pngBytes).map { String(format: "%02x", $0) }.joined()
        let key = Curve25519.Signing.PrivateKey()
        let pubB64 = key.publicKey.rawRepresentation.base64EncodedString()

        var identity = ConsentedIdentity(
            display_name: displayName,
            scheme: .selfAsSource,
            disclosure_text_sha256: IdentityConsentText.sha256,
            source_png_sha256: pngHash,
            scope: "v1.0+",
            issuer_public_key_b64: pubB64
        )

        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var clearable = identity
        clearable.signature_b64 = nil
        var message: Data
        do {
            message = try enc.encode(clearable)
        } catch {
            throw BenchError(message: "canonical encoding failed: \(error)", exitCode: 6)
        }
        message.append(pngBytes)
        let sig: Data
        do {
            sig = try key.signature(for: message)
        } catch {
            throw BenchError(message: "signing failed: \(error)", exitCode: 6)
        }
        identity.signature_b64 = sig.base64EncodedString()
        return identity
    }

    // MARK: - PNG <-> CVPixelBuffer

    /// Decode PNG bytes into a fresh BGRA `CVPixelBuffer` at the PNG's native size.
    /// The runtime pipeline always hands a BGRA IOSurface-backed buffer to the
    /// PhotorealBackend; we replicate the same flavor here so the bench exercises the
    /// same code path.
    static func makePixelBuffer(fromPNG pngBytes: Data) throws -> CVPixelBuffer {
        guard let src = CGImageSourceCreateWithData(pngBytes as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw BenchError(message: "PNG decode failed", exitCode: 3)
        }
        let w = cg.width
        let h = cg.height

        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            w, h,
            kCVPixelFormatType_32BGRA,
            [
                kCVPixelBufferIOSurfacePropertiesKey: [:],
                kCVPixelBufferMetalCompatibilityKey: true,
            ] as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let buf = pb else {
            throw BenchError(message: "CVPixelBufferCreate failed (status=\(status))", exitCode: 7)
        }

        let ci = CIImage(cgImage: cg)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        ctx.render(ci, to: buf)
        return buf
    }

    /// Write a BGRA `CVPixelBuffer` to disk as a PNG via ImageIO.
    static func writePNG(pixelBuffer: CVPixelBuffer, to url: URL) throws {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let cg = ctx.createCGImage(ci, from: ci.extent, format: .RGBA8, colorSpace: colorSpace) else {
            throw BenchError(message: "CGImage creation failed", exitCode: 8)
        }

        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1, nil
        ) else {
            throw BenchError(message: "CGImageDestination create failed at \(url.path)", exitCode: 8)
        }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw BenchError(message: "PNG write failed at \(url.path)", exitCode: 8)
        }
    }

    // MARK: - Helpers

    static func formatMs(_ ns: UInt64) -> String {
        let ms = Double(ns) / 1_000_000.0
        return String(format: "%.2f ms", ms)
    }

    // MARK: - Usage

    static func printUsage() {
        FileHandle.standardError.write(Data("""
        mirrormesh-photoreal-bench \(MirrorMeshCore.version)
        Run the photoreal inference graph standalone on a source + driver PNG pair.
        Used for Phase 1 of the photoreal v2 plan — diff against the upstream Python
        reference to localize a Swift-side bug to inference / composition / composite.

        Usage:
          mirrormesh-photoreal-bench \\
            --source <source.png> \\
            --driver <driver.png> \\
            --out <output.png> \\
            [--kind liveportrait|fomm]   default: liveportrait
            [--models-dir <dir>]         default: ./models
            [--dump-tensors <dir>]       dump each submodel boundary's MLMultiArray to <dir>/
                                          as <name>.bin (raw float32) + <name>.json (shape).
                                          Phase 2 v2 plan validation tool — diff against the
                                          Python reference to certify MPSGraph submodel ports.
            [--quiet]                    machine-readable: prints only the output path on success

        Output:
          identity:       <uuid> (self-as-source)
          prepareSource:  <ms>
          reenact:        <ms>
          write:          <ms>
          output:         <path>
          total:          <ms>

        """.utf8))
    }
}

// MARK: - Argument parsing

struct Args {
    let sourceURL: URL
    let driverURL: URL
    let outURL: URL
    let kind: PhotorealBackendKind
    let modelsDir: URL
    let tensorDumpDir: URL?
    let quiet: Bool

    init(args: [String]) throws {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }

        guard let sourcePath = value("--source") else {
            throw ArgError(message: "missing required --source <path>")
        }
        guard let driverPath = value("--driver") else {
            throw ArgError(message: "missing required --driver <path>")
        }
        guard let outPath = value("--out") else {
            throw ArgError(message: "missing required --out <path>")
        }

        let kindRaw = value("--kind") ?? "liveportrait"
        guard let kind = PhotorealBackendKind(rawValue: kindRaw) else {
            throw ArgError(message: "unknown --kind '\(kindRaw)'. Use liveportrait or fomm.")
        }
        let modelsDirPath = value("--models-dir") ?? FileManager.default.currentDirectoryPath + "/models"

        self.sourceURL = URL(fileURLWithPath: sourcePath)
        self.driverURL = URL(fileURLWithPath: driverPath)
        self.outURL    = URL(fileURLWithPath: outPath)
        self.kind      = kind
        self.modelsDir = URL(fileURLWithPath: modelsDirPath)
        if let dumpPath = value("--dump-tensors") {
            self.tensorDumpDir = URL(fileURLWithPath: dumpPath)
        } else {
            self.tensorDumpDir = nil
        }
        self.quiet     = args.contains("--quiet")
    }
}

struct ArgError: Error { let message: String }
struct BenchError: Error {
    let message: String
    let exitCode: Int32
}
