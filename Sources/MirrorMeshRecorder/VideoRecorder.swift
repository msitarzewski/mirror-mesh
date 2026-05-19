import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import MirrorMeshCore

/// Codec selection for the recorder. H.264 is the safe default for compatibility.
public enum VideoCodec: Sendable {
    case h264
    case hevc

    fileprivate var avCodec: AVVideoCodecType {
        switch self {
        case .h264: return .h264
        case .hevc: return .hevc
        }
    }
}

/// Writes watermarked frames to a .mov via AVAssetWriter. Actor isolation keeps
/// the AVAssetWriter pipeline single-threaded; we never hold a base-address lock
/// across an await.
public actor VideoRecorder {
    public enum RecorderError: Error {
        case cannotCreateWriter
        case cannotAddInput
        case startFailed
        case writerFailed(String)
        case alreadyFinalized
    }

    public let url: URL
    public let width: Int
    public let height: Int
    public let fps: Int
    public let codec: VideoCodec

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    private var sessionStarted = false
    private var startPTS: CMTime = .zero
    private var startHostNs: UInt64 = 0
    private var finalized = false
    private var dropped: Int = 0
    private var appended: Int = 0

    private static let timescale: CMTimeScale = 1_000_000_000

    public init(url: URL, width: Int, height: Int, fps: Int, codec: VideoCodec = .h264) throws {
        self.url = url
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec

        // Ensure parent dir exists and overwrite stale output.
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            throw RecorderError.cannotCreateWriter
        }
        self.writer = w

        let settings: [String: Any] = [
            AVVideoCodecKey: codec.avCodec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ]
        let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        inp.expectsMediaDataInRealTime = true
        self.input = inp

        guard writer.canAdd(inp) else {
            throw RecorderError.cannotAddInput
        }
        writer.add(inp)

        // Adaptor uses BGRA — the format the pipeline already produces.
        let sourceAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        self.adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: inp,
            sourcePixelBufferAttributes: sourceAttrs
        )

        guard writer.startWriting() else {
            throw RecorderError.startFailed
        }
    }

    /// Appends a watermarked frame. Drops the frame if the encoder isn't ready.
    public func append(_ frame: WatermarkedFrame) async {
        guard !finalized else { return }

        // Begin the session at the first frame so PTS starts at zero.
        if !sessionStarted {
            startHostNs = frame.hostTimeNs
            startPTS = .zero
            writer.startSession(atSourceTime: startPTS)
            sessionStarted = true
        }

        guard input.isReadyForMoreMediaData else {
            dropped &+= 1
            return
        }

        let deltaNs: Int64 = Int64(bitPattern: frame.hostTimeNs &- startHostNs)
        let pts = CMTime(value: deltaNs, timescale: Self.timescale)

        if !adaptor.append(frame.pixelBuffer, withPresentationTime: pts) {
            dropped &+= 1
        } else {
            appended &+= 1
        }
    }

    /// Marks the input finished and waits for the writer to flush.
    public func finalize() async throws {
        guard !finalized else { throw RecorderError.alreadyFinalized }
        finalized = true
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status == .failed {
            throw RecorderError.writerFailed(writer.error?.localizedDescription ?? "unknown")
        }
    }

    public var droppedFrameCount: Int { dropped }
    public var appendedFrameCount: Int { appended }
}
