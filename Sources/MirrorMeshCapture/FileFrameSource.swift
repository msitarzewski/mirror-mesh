import Foundation
import AVFoundation
import CoreVideo
import CoreMedia
import MirrorMeshCore

/// How `FileFrameSource` paces frames it reads from disk.
public enum PaceMode: Sendable {
    /// Honor each sample's presentation timestamp from the asset (real-time playback).
    case file
    /// Ignore timing — yield frames as fast as the reader can produce them. Useful for CI.
    case asFast
}

/// File-backed frame source. Reads a video asset via `AVAssetReader` and yields BGRA
/// `CapturedFrame`s identical in shape to live/synthetic sources, so the pipeline cannot
/// tell the difference. See `memory-bank/release/v0.2.0/M15-fixture.md`.
public actor FileFrameSource: FrameSource {
    public enum FileError: Error, CustomStringConvertible, Sendable {
        case noVideoTrack
        case readerSetupFailed(String)
        case readFailed(String)

        public var description: String {
            switch self {
            case .noVideoTrack:                 return "Asset has no video track"
            case .readerSetupFailed(let m):     return "AVAssetReader setup failed: \(m)"
            case .readFailed(let m):            return "Frame read failed: \(m)"
            }
        }
    }

    private let url: URL
    private let looping: Bool
    private let pace: PaceMode
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<CapturedFrame>.Continuation?

    public init(url: URL, looping: Bool = false, pace: PaceMode = .file) {
        self.url = url
        self.looping = looping
        self.pace = pace
    }

    public func start() async throws -> AsyncStream<CapturedFrame> {
        // Why: unbounded buffering so a slow downstream consumer doesn't lose fixture frames;
        // file playback is bounded in length so total memory is bounded too.
        let stream = AsyncStream<CapturedFrame>(bufferingPolicy: .unbounded) { cont in
            self.continuation = cont
        }
        // Validate up front so callers see errors at start() rather than mid-stream.
        _ = try await makeReader()
        task = Task { [weak self] in
            await self?.runLoop()
        }
        return stream
    }

    public func stop() async {
        task?.cancel()
        continuation?.finish()
        continuation = nil
        task = nil
    }

    private func runLoop() async {
        repeat {
            do {
                try await readOnce()
            } catch {
                // Surface as warning by terminating the stream; pipeline treats EOF same way.
                break
            }
        } while looping && !Task.isCancelled
        continuation?.finish()
    }

    private func makeReader() async throws -> (AVAssetReader, AVAssetReaderTrackOutput, CMTimeScale) {
        let asset = AVURLAsset(url: url)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .video)
        } catch {
            throw FileError.readerSetupFailed("\(error)")
        }
        guard let track = tracks.first else { throw FileError.noVideoTrack }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw FileError.readerSetupFailed("\(error)")
        }
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw FileError.readerSetupFailed("cannot add track output")
        }
        reader.add(output)
        // macOS 13+ async accessor; the deprecated sync property triggers a build warning.
        let timescale = try await track.load(.naturalTimeScale)
        return (reader, output, timescale)
    }

    private func readOnce() async throws {
        let (reader, output, _) = try await makeReader()
        guard reader.startReading() else {
            throw FileError.readerSetupFailed(reader.error?.localizedDescription ?? "startReading failed")
        }

        var lastPtsNs: UInt64? = nil
        let wallStart = MirrorMeshCore.hostTimeNs()
        var firstPtsNs: UInt64? = nil

        while !Task.isCancelled {
            guard let sample = output.copyNextSampleBuffer() else { break }
            guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let ptsNs: UInt64 = pts.isValid
                ? UInt64(max(0.0, CMTimeGetSeconds(pts)) * 1_000_000_000)
                : (lastPtsNs.map { $0 &+ 33_333_333 } ?? 0)

            if pace == .file, let first = firstPtsNs {
                let elapsedFromStart = ptsNs &- first
                let wallElapsed = MirrorMeshCore.hostTimeNs() &- wallStart
                if elapsedFromStart > wallElapsed {
                    let sleepNs = elapsedFromStart - wallElapsed
                    try? await Task.sleep(nanoseconds: sleepNs)
                }
            } else if pace == .file {
                firstPtsNs = ptsNs
            }

            let frameID = FrameIDGenerator.shared.next()
            let hostNow = MirrorMeshCore.hostTimeNs()
            let frame = CapturedFrame(
                frameID: frameID,
                hostTimeNs: hostNow,
                pixelBuffer: pb,
                width: CVPixelBufferGetWidth(pb),
                height: CVPixelBufferGetHeight(pb)
            )
            continuation?.yield(frame)
            lastPtsNs = ptsNs
        }

        if reader.status == .failed {
            throw FileError.readFailed(reader.error?.localizedDescription ?? "unknown")
        }
        reader.cancelReading()
    }
}
