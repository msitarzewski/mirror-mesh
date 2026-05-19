import Foundation
import CoreVideo
import MirrorMeshCore
import MirrorMeshCapture
import MirrorMeshVision
import MirrorMeshSolver
import MirrorMeshRender
import MirrorMeshWatermark
import MirrorMeshOutput
// Why: `MirrorMeshAppKit` is not declared as a selftest dependency in `Package.swift` and the
// task scope forbids modifying that file. AppKit-level smoke coverage runs under the future
// Xcode-based test plan; here we touch only the canonical types (`ConsentRecord`, `ConsentText`
// equivalents) that already live in `MirrorMeshWatermark`.

// Lightweight assertion harness that runs without XCTest / swift-testing.
// Designed for Command Line Tools environments where the macro plugin isn't available.

@MainActor
final class SelfTestRunner {
    private(set) var passed = 0
    private(set) var failed: [(name: String, message: String)] = []

    func check(_ name: String, _ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "") {
        if condition() {
            passed += 1
            print("  \u{2713} \(name)")
        } else {
            let msg = message()
            failed.append((name, msg))
            print("  \u{2717} \(name)\(msg.isEmpty ? "" : ": \(msg)")")
        }
    }

    func suite(_ name: String, _ body: () -> Void) {
        print("\n[\(name)]")
        body()
    }

    func summarize() -> Int32 {
        let total = passed + failed.count
        print("\n\(passed)/\(total) passed, \(failed.count) failed")
        return failed.isEmpty ? 0 : 1
    }
}

@main
@MainActor
struct SelfTest {
    static func main() {
        let runner = SelfTestRunner()

        runner.suite("MirrorMeshCore") {
            runner.check("version is non-empty", !MirrorMeshCore.version.isEmpty)
        }
        runner.suite("MirrorMeshCapture") {
            runner.check("module name", MirrorMeshCapture.moduleName == "MirrorMeshCapture")
        }
        runner.suite("MirrorMeshVision") {
            runner.check("module name", MirrorMeshVision.moduleName == "MirrorMeshVision")
        }
        runner.suite("MirrorMeshSolver") {
            runner.check("module name", MirrorMeshSolver.moduleName == "MirrorMeshSolver")
        }
        runner.suite("MirrorMeshRender") {
            runner.check("module name", MirrorMeshRender.moduleName == "MirrorMeshRender")
        }
        runner.suite("MirrorMeshWatermark") {
            runner.check("module name", MirrorMeshWatermark.moduleName == "MirrorMeshWatermark")
        }
        runner.suite("MirrorMeshOutput") {
            runner.check("module name", MirrorMeshOutput.moduleName == "MirrorMeshOutput")
        }

        runner.suite("MirrorMeshSolver/GeometricSolver") {
            // Build a synthetic neutral landmark set conforming to LandmarkIndex bands.
            func makeNeutralPoints() -> [LandmarkPoint] {
                var pts = Array(repeating: LandmarkPoint(x: 0.5, y: 0.5), count: 76)
                // Mouth: 40..55. Upper lip (44) above lower lip (52); corners at 40 (left) / 48 (right).
                pts[40] = LandmarkPoint(x: 0.40, y: 0.62)  // left corner
                pts[44] = LandmarkPoint(x: 0.50, y: 0.60)  // upper lip mid
                pts[48] = LandmarkPoint(x: 0.60, y: 0.62)  // right corner
                pts[52] = LandmarkPoint(x: 0.50, y: 0.64)  // lower lip mid
                // Fill mouth ring with a coarse ellipse so width/height ratios are well-defined.
                for i in 40..<56 {
                    let theta = Double(i - 40) / 16.0 * 2 * .pi
                    pts[i] = LandmarkPoint(x: 0.50 + Float(cos(theta)) * 0.10,
                                           y: 0.62 + Float(sin(theta)) * 0.02)
                }
                // Re-pin the four anchors so the index assumptions hold.
                pts[40] = LandmarkPoint(x: 0.40, y: 0.62)
                pts[44] = LandmarkPoint(x: 0.50, y: 0.60)
                pts[48] = LandmarkPoint(x: 0.60, y: 0.62)
                pts[52] = LandmarkPoint(x: 0.50, y: 0.64)
                // Eyes: left 16..23 upper=18 lower=22; right 24..31 upper=26 lower=30.
                pts[18] = LandmarkPoint(x: 0.38, y: 0.38)
                pts[22] = LandmarkPoint(x: 0.38, y: 0.42)
                pts[26] = LandmarkPoint(x: 0.62, y: 0.38)
                pts[30] = LandmarkPoint(x: 0.62, y: 0.42)
                // Brows in detail band.
                pts[64] = LandmarkPoint(x: 0.40, y: 0.30)
                pts[67] = LandmarkPoint(x: 0.34, y: 0.30)
                pts[70] = LandmarkPoint(x: 0.60, y: 0.30)
                pts[73] = LandmarkPoint(x: 0.66, y: 0.30)
                // Outline 0..15 for cheekPuff width baseline.
                for i in 0..<16 {
                    let theta = Double(i) / 16.0 * 2 * .pi
                    pts[i] = LandmarkPoint(x: 0.50 + Float(cos(theta)) * 0.25,
                                           y: 0.50 + Float(sin(theta)) * 0.30)
                }
                pts[36] = LandmarkPoint(x: 0.50, y: 0.50)
                return pts
            }

            let bbox = CGRect(x: 0.25, y: 0.20, width: 0.50, height: 0.60)
            let neutralPts = makeNeutralPoints()

            // Calibrate over 35 frames so the solver is locked.
            let solver = GeometricSolver()
            for _ in 0..<35 {
                let frame = LandmarkFrame(
                    frameID: FrameIDGenerator.shared.next(),
                    hostTimeNs: MirrorMeshCore.hostTimeNs(),
                    points: neutralPts,
                    confidence: 0.99,
                    faceBoundingBoxNorm: bbox
                )
                _ = solver.solve(frame)
            }
            runner.check("calibrated after 35 frames", solver.isCalibrated)

            // Test 1: at neutral, all coefficients should be ~zero.
            let neutralFrame = LandmarkFrame(
                frameID: FrameIDGenerator.shared.next(),
                hostTimeNs: MirrorMeshCore.hostTimeNs(),
                points: neutralPts,
                confidence: 0.99,
                faceBoundingBoxNorm: bbox
            )
            let neutralResult = solver.solve(neutralFrame)
            let maxAtRest = neutralResult.coefficients.values.map { abs($0) }.max() ?? 0
            runner.check("neutral pose => all coefficients near zero", maxAtRest < 0.05,
                         "max coefficient was \(maxAtRest)")

            // Test 2: drop lower lip => jawOpen rises.
            var openPts = neutralPts
            openPts[52] = LandmarkPoint(x: 0.50, y: 0.74)  // lower lip pushed way down
            let openFrame = LandmarkFrame(
                frameID: FrameIDGenerator.shared.next(),
                hostTimeNs: MirrorMeshCore.hostTimeNs(),
                points: openPts,
                confidence: 0.99,
                faceBoundingBoxNorm: bbox
            )
            // Feed twice so smoothing settles toward the new value.
            _ = solver.solve(openFrame)
            let openResult = solver.solve(openFrame)
            runner.check("jaw drop raises jawOpen",
                         (openResult.coefficients[.jawOpen] ?? 0) > 0.3,
                         "jawOpen = \(openResult.coefficients[.jawOpen] ?? 0)")

            // Test 3: clamp under extreme inputs.
            var extremePts = neutralPts
            extremePts[52] = LandmarkPoint(x: 0.50, y: 5.0)  // absurd
            let extremeFrame = LandmarkFrame(
                frameID: FrameIDGenerator.shared.next(),
                hostTimeNs: MirrorMeshCore.hostTimeNs(),
                points: extremePts,
                confidence: 0.99,
                faceBoundingBoxNorm: bbox
            )
            let extremeResult = solver.solve(extremeFrame)
            let inRange = extremeResult.coefficients.values.allSatisfy { $0 >= 0 && $0 <= 1 }
            runner.check("all coefficients clamped to [0,1] under extreme input", inRange)

            // Test 4: smile via mouth-corner outward displacement.
            var smilePts = neutralPts
            smilePts[40] = LandmarkPoint(x: 0.30, y: 0.60)  // left corner moves out + up
            smilePts[48] = LandmarkPoint(x: 0.70, y: 0.60)  // right corner moves out + up
            let smileFrame = LandmarkFrame(
                frameID: FrameIDGenerator.shared.next(),
                hostTimeNs: MirrorMeshCore.hostTimeNs(),
                points: smilePts,
                confidence: 0.99,
                faceBoundingBoxNorm: bbox
            )
            _ = solver.solve(smileFrame)
            let smileResult = solver.solve(smileFrame)
            runner.check("smile raises both smile coefficients",
                         (smileResult.coefficients[.mouthSmileLeft] ?? 0) > 0.1
                         && (smileResult.coefficients[.mouthSmileRight] ?? 0) > 0.1)

            // Test 5: NeutralPoseCalibrator behavior.
            let calib = NeutralPoseCalibrator(frameTarget: 5, alpha: 0.5)
            runner.check("calibrator starts uncalibrated", !calib.isCalibrated)
            for _ in 0..<5 {
                let f = LandmarkFrame(
                    frameID: FrameIDGenerator.shared.next(),
                    hostTimeNs: MirrorMeshCore.hostTimeNs(),
                    points: neutralPts,
                    confidence: 1.0,
                    faceBoundingBoxNorm: bbox
                )
                calib.observe(f)
            }
            runner.check("calibrator locks at frameTarget", calib.isCalibrated)
            runner.check("neutralPoints available after calibration", calib.neutralPoints() != nil)
            calib.reset()
            runner.check("reset clears calibration", !calib.isCalibrated && calib.neutralPoints() == nil)

            // Test 6: BlendshapeSmoother converges toward steady input.
            var smoother = BlendshapeSmoother(alpha: 0.5)
            let target: [BlendshapeKey: Float] = [.jawOpen: 1.0]
            var last: Float = 0
            for _ in 0..<10 { last = smoother.smooth(target)[.jawOpen] ?? 0 }
            runner.check("smoother converges toward steady input", last > 0.99)
        }

        runner.suite("MirrorMeshRender/Renderer") {
            do {
                let ctx = try MetalContext()
                let outW = 640
                let outH = 360
                let renderer = try Renderer(context: ctx,
                                            outputSize: (width: outW, height: outH))

                let pool = PixelBufferPool(width: outW, height: outH)
                guard let pb = pool.acquire() else {
                    runner.check("source pixel buffer acquired", false, "pool returned nil")
                    return
                }
                let captured = CapturedFrame(
                    frameID: FrameIDGenerator.shared.next(),
                    hostTimeNs: MirrorMeshCore.hostTimeNs(),
                    pixelBuffer: pb,
                    width: outW,
                    height: outH
                )

                let out = renderer.render(captured: captured,
                                          landmarks: nil,
                                          blendshapes: nil)
                runner.check("render returns non-nil", out != nil)
                runner.check("output width matches",  out?.width == outW)
                runner.check("output height matches", out?.height == outH)
                runner.check("frame id preserved",    out?.frameID == captured.frameID)
            } catch {
                runner.check("metal pipeline init", false, "\(error)")
            }
        }

        runner.suite("Watermark roundtrip") {
            let pool = PixelBufferPool(width: 320, height: 240)
            guard let buffer = pool.acquire() else {
                runner.check("acquired pixel buffer from pool", false, "pool returned nil")
                return
            }
            fillPixelBuffer(buffer, r: 64, g: 128, b: 200)

            let frame = RenderedFrame(
                frameID: FrameIDGenerator.shared.next(),
                hostTimeNs: MirrorMeshCore.hostTimeNs(),
                pixelBuffer: buffer,
                width: 320,
                height: 240
            )

            let signer = FrameSigner()
            let badge: VisibleBadge
            do {
                badge = try VisibleBadge()
            } catch {
                runner.check("badge constructible at default opacity", false, "\(error)")
                return
            }
            let watermarker = Watermarker(signer: signer, badge: badge)
            let wm = watermarker.watermark(frame)

            runner.check("signature non-empty (64 bytes Ed25519)", wm.signature.count == 64)
            runner.check("content digest is 32-byte SHA-256", wm.contentDigest.count == 32)
            runner.check("public key is 32-byte Ed25519 raw key", signer.publicKey.count == 32)

            let ok = Verifier.verifyFrame(
                buffer: wm.pixelBuffer,
                signature: wm.signature,
                expectedFrameID: wm.frameID.value,
                expectedHostTimeNs: wm.hostTimeNs,
                publicKey: signer.publicKey
            )
            runner.check("untampered frame verifies", ok)

            tamperOneByte(wm.pixelBuffer)
            let okAfter = Verifier.verifyFrame(
                buffer: wm.pixelBuffer,
                signature: wm.signature,
                expectedFrameID: wm.frameID.value,
                expectedHostTimeNs: wm.hostTimeNs,
                publicKey: signer.publicKey
            )
            runner.check("tampered frame is rejected", !okAfter)

            let okWrongID = Verifier.verifyDigest(
                wm.contentDigest,
                signature: wm.signature,
                expectedFrameID: wm.frameID.value &+ 1,
                expectedHostTimeNs: wm.hostTimeNs,
                publicKey: signer.publicKey
            )
            runner.check("wrong frameID is rejected", !okWrongID)
        }

        runner.suite("Manifest roundtrip") {
            let signer = FrameSigner()
            let consent = ConsentRecord(
                scheme: .selfAsSource,
                accepted_at: Date(),
                user_disclosure_text_sha256: ConsentRecord.hashDisclosure("I am the source of this face.")
            )
            let manifest = SessionManifest(
                started_at: Date(),
                device: DeviceInfo.current(),
                pipeline: PipelineConfig.defaultV0(),
                consent: consent,
                public_key_b64: signer.publicKey.base64EncodedString()
            )
            let tmpDir = FileManager.default.temporaryDirectory
                .appendingPathComponent("mirrormesh-selftest-\(UUID().uuidString)")
            let manifestURL = tmpDir.appendingPathComponent("session.manifest.json")
            let writer = ManifestWriter(url: manifestURL, signer: signer, manifest: manifest)

            let result: Bool = blockingAwait {
                for _ in 0..<10 {
                    await writer.recordFrames(1)
                }
                do {
                    try await writer.finalize()
                    return true
                } catch {
                    return false
                }
            }
            runner.check("finalize succeeds", result)
            runner.check("manifest file exists on disk", FileManager.default.fileExists(atPath: manifestURL.path))

            guard let data = try? Data(contentsOf: manifestURL),
                  let loaded = try? ManifestCodec.decode(data) else {
                runner.check("loaded manifest decodes", false)
                return
            }
            runner.check("manifest_version is 1.0", loaded.manifest_version == "1.0")
            runner.check("frame_count is 10", loaded.frame_count == 10)
            runner.check("loaded manifest signature verifies", Verifier.verifyManifest(loaded))

            var tampered = loaded
            tampered.frame_count = 999_999
            runner.check("tampered frame_count is rejected", !Verifier.verifyManifest(tampered))

            var tampered2 = loaded
            tampered2.consent.scheme = .stylizedNonHuman
            runner.check("tampered consent is rejected", !Verifier.verifyManifest(tampered2))

            let knownHash = ConsentRecord.hashDisclosure("hello")
            runner.check("SHA-256 of 'hello' matches RFC vector",
                         knownHash == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")

            // Leave a copy at a known path so the CLI verifier can be smoke-tested out-of-band.
            let stableCopy = FileManager.default.temporaryDirectory
                .appendingPathComponent("mirrormesh-selftest-latest.json")
            try? FileManager.default.removeItem(at: stableCopy)
            try? FileManager.default.copyItem(at: manifestURL, to: stableCopy)
            try? FileManager.default.removeItem(at: tmpDir)
        }

        // MirrorMeshAppKit smoke coverage cannot run here without amending
        // `Package.swift` to add the dependency. The canonical consent text + record types
        // exercised by AppKit live in `MirrorMeshWatermark` and are covered in the
        // "Manifest roundtrip" suite above.

        exit(runner.summarize())
    }
}

// Synchronously runs an async closure on a fresh task and blocks until it completes.
// Selftest must remain a non-async main(); semaphore is the minimum surface to bridge.
@MainActor
func blockingAwait<T: Sendable>(_ body: @Sendable @escaping () async -> T) -> T {
    let sem = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached {
        let v = await body()
        box.value = v
        sem.signal()
    }
    sem.wait()
    return box.value!
}

final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

func fillPixelBuffer(_ buffer: CVPixelBuffer, r: UInt8, g: UInt8, b: UInt8) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    for row in 0..<height {
        let rowPtr = base.advanced(by: row * bytesPerRow).assumingMemoryBound(to: UInt8.self)
        for col in 0..<width {
            let off = col * 4
            // BGRA in memory order.
            rowPtr[off + 0] = b
            rowPtr[off + 1] = g
            rowPtr[off + 2] = r
            rowPtr[off + 3] = 255
        }
    }
}

func tamperOneByte(_ buffer: CVPixelBuffer) {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
    let p = base.assumingMemoryBound(to: UInt8.self)
    p[0] = p[0] &+ 1
}

func dummyPixelBuffer() -> CVPixelBuffer {
    var pb: CVPixelBuffer!
    let attrs: [String: Any] = [
        kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
    ]
    CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
    return pb
}
