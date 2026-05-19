import Testing
import Foundation
import CoreVideo
@testable import MirrorMeshVirtualCamera
import MirrorMeshCore

@Suite("MirrorMeshVirtualCamera")
struct VirtualCameraChannelTests {

    @Test("wire payload round-trips through JSON")
    func payloadRoundTrip() throws {
        let pixels = Data((0..<(4 * 2 * 2)).map { UInt8($0) })  // 2x2 BGRA
        let payload = VirtualCameraFramePayload(
            frameID: 42,
            hostTimeNs: 123_456_789,
            width: 2,
            height: 2,
            bytesPerRow: 8,
            pixels: pixels,
            signature: Data([0xAA, 0xBB]),
            contentDigest: Data([0x01, 0x02, 0x03])
        )
        let data = try VirtualCameraWire.encode(payload)
        let decoded = try VirtualCameraWire.decode(data)
        #expect(decoded.frameID == 42)
        #expect(decoded.hostTimeNs == 123_456_789)
        #expect(decoded.width == 2 && decoded.height == 2)
        #expect(decoded.bytesPerRow == 8)
        #expect(decoded.pixels == pixels)
        #expect(decoded.signature == Data([0xAA, 0xBB]))
        #expect(decoded.contentDigest == Data([0x01, 0x02, 0x03]))
    }

    @Test("packPixels extracts contiguous BGRA bytes from a CVPixelBuffer")
    func packPixelsBGRA() throws {
        // Build a tiny BGRA pixel buffer with known content.
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, 4, 4,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &pb)
        #expect(status == kCVReturnSuccess)
        guard let buf = pb else { return }
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let stride = CVPixelBufferGetBytesPerRow(buf)
        // Write a recognizable pattern: per-pixel ramp.
        for y in 0..<4 {
            for x in 0..<4 {
                let px = base.advanced(by: y * stride + x * 4).assumingMemoryBound(to: UInt8.self)
                px[0] = UInt8(x); px[1] = UInt8(y); px[2] = UInt8(x &+ y); px[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])

        let frame = WatermarkedFrame(
            frameID: FrameID(7),
            hostTimeNs: 1,
            pixelBuffer: buf, width: 4, height: 4,
            signature: Data(),
            contentDigest: Data()
        )
        let result = VirtualCameraWire.packPixels(from: frame)
        #expect(result != nil)
        #expect(result?.bytesPerRow == stride)
        #expect(result?.pixels.count == stride * 4)
    }

    @Test("installer reports notInstallable in SwiftPM test context")
    func installerNotInstallable() {
        // SwiftPM tests run inside xctest, not an .app bundle; the diagnosis must reject install.
        let diag = VirtualCameraInstaller.installabilityDiagnosis()
        #expect(diag != nil)
        #expect(VirtualCameraInstaller.isInstallable == false)
    }

    @Test("install() throws notInstallable without crashing in dev build")
    func installerInstallThrows() async {
        do {
            try await VirtualCameraInstaller.install()
            #expect(Bool(false), "install() must throw in the test harness")
        } catch let err as VirtualCameraInstallerError {
            if case .notInstallable = err { /* expected */ } else {
                #expect(Bool(false), "Expected .notInstallable, got \(err)")
            }
        } catch {
            #expect(Bool(false), "Unexpected error type: \(error)")
        }
    }

    @Test("module marker is exposed")
    func moduleMarker() {
        #expect(MirrorMeshVirtualCamera.moduleName == "MirrorMeshVirtualCamera")
        #expect(MirrorMeshVirtualCamera.machServiceName == "ai.mirrormesh.VirtualCamera")
        #expect(MirrorMeshVirtualCamera.extensionBundleIdentifier == "ai.mirrormesh.VirtualCameraExtension")
    }
}
