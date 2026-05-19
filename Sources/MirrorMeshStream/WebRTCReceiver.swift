import Foundation
import CoreVideo
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import WebRTC

/// Receive-only peer used by the test harness + local-loop CLI. Consumes a
/// single video track, dumps every Nth decoded frame to PNG, and counts the
/// frames it observed.
public final class WebRTCReceiver: NSObject, @unchecked Sendable {

    public enum ReceiverError: Error, Sendable {
        case answerFailed(String)
        case setLocalFailed(String)
        case setRemoteFailed(String)
        case noPeerConnection
    }

    /// Notified for every locally-gathered ICE candidate so the harness can
    /// forward to the paired sender.
    public var onLocalIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?
    /// Notified each time a decoded video frame is observed (post-PNG dump).
    public var onFrameReceived: (@Sendable (Int) -> Void)?

    public private(set) var framesReceived: Int = 0
    public let outputDirectory: URL
    public let dumpEveryN: Int

    private let factory: RTCPeerConnectionFactory
    private var peerConnection: RTCPeerConnection?
    private var renderer: FrameSink?
    private let renderQueue = DispatchQueue(label: "mirrormesh.stream.receiver.render")
    private let ciContext = CIContext(options: nil)

    public init(outputDirectory: URL,
                dumpEveryN: Int = 1,
                config: RTCConfiguration = WebRTCSender.defaultConfig()) {
        WebRTCRuntime.bootstrap()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        self.outputDirectory = outputDirectory
        self.dumpEveryN = max(1, dumpEveryN)
        super.init()
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        self.peerConnection = factory.peerConnection(
            with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: self
        )
        // Why: pre-create a recvonly transceiver so the answer always offers a video m-section,
        // even before remote SDP arrives.
        let initRecv = RTCRtpTransceiverInit()
        initRecv.direction = .recvOnly
        _ = peerConnection?.addTransceiver(of: .video, init: initRecv)
    }

    public func setRemoteOffer(_ offer: RTCSessionDescription) async throws -> RTCSessionDescription {
        guard let pc = peerConnection else { throw ReceiverError.noPeerConnection }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(offer) { err in
                if let err { cont.resume(throwing: ReceiverError.setRemoteFailed(err.localizedDescription)) }
                else { cont.resume() }
            }
        }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let answer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.answer(for: constraints) { sdp, err in
                if let err { cont.resume(throwing: ReceiverError.answerFailed(err.localizedDescription)); return }
                guard let sdp else { cont.resume(throwing: ReceiverError.answerFailed("nil sdp")); return }
                cont.resume(returning: sdp)
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(answer) { err in
                if let err { cont.resume(throwing: ReceiverError.setLocalFailed(err.localizedDescription)) }
                else { cont.resume() }
            }
        }
        return answer
    }

    public func addRemoteIceCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { _ in }
    }

    public func stop() {
        peerConnection?.close()
        peerConnection = nil
    }

    private func dump(_ pixelBuffer: CVPixelBuffer, index: Int) {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard let cg = ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: w, height: h)) else { return }
        let url = outputDirectory.appendingPathComponent(String(format: "frame_%05d.png", index))
        guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, cg, nil)
        CGImageDestinationFinalize(dst)
    }
}

extension WebRTCReceiver: RTCPeerConnectionDelegate {
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        onLocalIceCandidate?(candidate)
    }
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    public func peerConnection(_ peerConnection: RTCPeerConnection,
                                didAdd rtpReceiver: RTCRtpReceiver,
                                streams mediaStreams: [RTCMediaStream]) {
        guard let track = rtpReceiver.track as? RTCVideoTrack else { return }
        let sink = FrameSink { [weak self] frame in
            guard let self else { return }
            self.renderQueue.async {
                self.framesReceived &+= 1
                let idx = self.framesReceived
                if idx % self.dumpEveryN == 0,
                   let cv = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer {
                    self.dump(cv, index: idx)
                }
                self.onFrameReceived?(idx)
            }
        }
        self.renderer = sink
        track.add(sink)
    }
}

/// Why: `RTCVideoRenderer` is an Obj-C protocol; we wrap a Swift closure so the
/// receiver can keep its frame-counting logic in one place.
final class FrameSink: NSObject, RTCVideoRenderer, @unchecked Sendable {
    private let onFrame: @Sendable (RTCVideoFrame) -> Void

    init(onFrame: @escaping @Sendable (RTCVideoFrame) -> Void) {
        self.onFrame = onFrame
    }

    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        onFrame(frame)
    }
}
