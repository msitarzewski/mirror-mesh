import Foundation
import AVFoundation
import CoreVideo
import MirrorMeshCore

/// Live camera capture via AVFoundation. Used by the SwiftUI app.
/// Stays inert in headless / sandboxed environments — call `SyntheticFrameSource` there.
public final class LiveCaptureSource: NSObject, FrameSource,
                                      AVCaptureVideoDataOutputSampleBufferDelegate,
                                      @unchecked Sendable {
    private let config: CaptureConfig
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "ai.mirrormesh.capture.output", qos: .userInteractive)
    private var continuation: AsyncStream<CapturedFrame>.Continuation?

    public init(config: CaptureConfig = .default) {
        self.config = config
    }

    public func start() async throws -> AsyncStream<CapturedFrame> {
        let granted = await Self.requestPermission()
        guard granted else { throw CaptureError.permissionDenied }
        try configureSession()

        let stream = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(2)) { cont in
            self.continuation = cont
        }
        session.startRunning()
        return stream
    }

    public func stop() async {
        if session.isRunning { session.stopRunning() }
        continuation?.finish()
        continuation = nil
    }

    private static func requestPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:    return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .video) { ok in
                    cont.resume(returning: ok)
                }
            }
        default:             return false
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        guard let device = pickDevice(from: discovery.devices) else {
            throw CaptureError.noDeviceAvailable
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            } else {
                throw CaptureError.sessionFailed("cannot add input")
            }
        } catch {
            throw CaptureError.sessionFailed("\(error)")
        }

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CaptureError.sessionFailed("cannot add output")
        }
        session.addOutput(videoOutput)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if config.lockExposure, device.isExposureModeSupported(.locked) {
                device.exposureMode = .locked
            }
            if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
            if device.isWhiteBalanceModeSupported(.locked) { device.whiteBalanceMode = .locked }
        } catch {
            // non-fatal: continue with auto modes
        }
    }

    private func pickDevice(from devices: [AVCaptureDevice]) -> AVCaptureDevice? {
        if config.preferContinuityCamera,
           let cc = devices.first(where: { $0.deviceType == .continuityCamera }) {
            return cc
        }
        return devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? devices.first
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let host = pts.isValid
            ? UInt64(CMTimeGetSeconds(pts) * 1_000_000_000)
            : MirrorMeshCore.hostTimeNs()
        let frameID = FrameIDGenerator.shared.next()
        // Signpost around delegate body so Instruments shows real capture wall-time per frame.
        let sp = Signpost.begin(Signpost.capture, frame: frameID)
        defer { Signpost.end(Signpost.capture, frame: frameID, id: sp) }
        let frame = CapturedFrame(
            frameID: frameID,
            hostTimeNs: host,
            pixelBuffer: pb,
            width: CVPixelBufferGetWidth(pb),
            height: CVPixelBufferGetHeight(pb)
        )
        continuation?.yield(frame)
        TelemetryBus.emit(.stageEnd(stage: .capture, frame: frame.frameID, hostTimeNs: host))
    }
}
