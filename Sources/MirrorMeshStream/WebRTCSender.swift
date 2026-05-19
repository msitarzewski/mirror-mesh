import Foundation
import CoreVideo
import MirrorMeshCore
@preconcurrency import WebRTC

/// Outgoing-only WebRTC peer that publishes a single video track driven by
/// `WatermarkedFrame`s from the MirrorMesh pipeline.
///
/// Why `@unchecked Sendable`: libwebrtc's Obj-C types are not annotated
/// `Sendable`; we serialize state mutation through `factoryQueue` and the
/// peer-connection's own thread, so cross-actor handoff is safe in practice.
public final class WebRTCSender: NSObject, @unchecked Sendable {

    public enum SenderError: Error, Sendable {
        case offerFailed(String)
        case setLocalFailed(String)
        case setRemoteFailed(String)
        case noPeerConnection
    }

    /// Per-peer signalling delegate input. We forward locally-gathered ICE
    /// candidates to the paired receiver in the local-loop CLI.
    public var onLocalIceCandidate: (@Sendable (RTCIceCandidate) -> Void)?

    public let trackId: String
    public let streamId: String

    private let factory: RTCPeerConnectionFactory
    private let videoSource: RTCVideoSource
    private let videoTrack: RTCVideoTrack
    private var peerConnection: RTCPeerConnection?
    private let config: RTCConfiguration

    public init(config: RTCConfiguration = WebRTCSender.defaultConfig(),
                trackId: String = "mm-video-0",
                streamId: String = "mm-stream-0") {
        // Why: register once per process — calling twice is benign but logs spam.
        WebRTCRuntime.bootstrap()
        let encoder = RTCDefaultVideoEncoderFactory()
        let decoder = RTCDefaultVideoDecoderFactory()
        self.factory = RTCPeerConnectionFactory(encoderFactory: encoder, decoderFactory: decoder)
        self.videoSource = factory.videoSource()
        self.videoTrack = factory.videoTrack(with: videoSource, trackId: trackId)
        self.config = config
        self.trackId = trackId
        self.streamId = streamId
        super.init()
        self.peerConnection = factory.peerConnection(
            with: config,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: self
        )
        // Why: addTrack on the outgoing-only peer; receive direction is dropped on the other side.
        _ = peerConnection?.add(videoTrack, streamIds: [streamId])
    }

    public static func defaultConfig() -> RTCConfiguration {
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        // Why: no STUN/TURN by default — local-loop / LAN tests don't need it.
        cfg.iceServers = []
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        return cfg
    }

    public func createOffer() async throws -> RTCSessionDescription {
        guard let pc = peerConnection else { throw SenderError.noPeerConnection }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                "OfferToReceiveAudio": "false",
                "OfferToReceiveVideo": "false",
            ],
            optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, err in
                if let err { cont.resume(throwing: SenderError.offerFailed(err.localizedDescription)); return }
                guard let sdp else { cont.resume(throwing: SenderError.offerFailed("nil sdp")); return }
                cont.resume(returning: sdp)
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offer) { err in
                if let err { cont.resume(throwing: SenderError.setLocalFailed(err.localizedDescription)) }
                else { cont.resume() }
            }
        }
        return offer
    }

    public func setRemoteAnswer(_ answer: RTCSessionDescription) async throws {
        guard let pc = peerConnection else { throw SenderError.noPeerConnection }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setRemoteDescription(answer) { err in
                if let err { cont.resume(throwing: SenderError.setRemoteFailed(err.localizedDescription)) }
                else { cont.resume() }
            }
        }
    }

    /// Forward an ICE candidate gathered by the remote peer.
    public func addRemoteIceCandidate(_ candidate: RTCIceCandidate) {
        peerConnection?.add(candidate) { _ in }
    }

    /// Push the most recent watermarked frame into the outgoing track.
    public func append(_ frame: WatermarkedFrame) {
        let buffer = RTCCVPixelBuffer(pixelBuffer: frame.pixelBuffer)
        let timeNs = Int64(bitPattern: UInt64(frame.hostTimeNs))
        let rtcFrame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: timeNs)
        // Why: RTCVideoSource conforms to RTCVideoCapturerDelegate; the dummy capturer satisfies the API.
        videoSource.capturer(WebRTCRuntime.sharedCapturer, didCapture: rtcFrame)
    }

    public func stop() {
        peerConnection?.close()
        peerConnection = nil
    }
}

extension WebRTCSender: RTCPeerConnectionDelegate {
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
}

/// Process-wide WebRTC bootstrap + a no-op capturer used to satisfy
/// `RTCVideoCapturerDelegate.capturer(_:didCapture:)`.
enum WebRTCRuntime {
    private static var initialized = false
    private static let lock = NSLock()
    static let sharedCapturer: RTCVideoCapturer = {
        bootstrap()
        return RTCVideoCapturer()
    }()

    static func bootstrap() {
        lock.lock(); defer { lock.unlock() }
        if initialized { return }
        RTCInitializeSSL()
        initialized = true
    }
}
