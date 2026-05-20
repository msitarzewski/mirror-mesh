import Foundation
import AVFoundation
import MirrorMeshCore

/// Thin `AVAudioEngine` wrapper that exposes raw `AVAudioPCMBuffer`s in 16 kHz
/// mono Float32 — Speech's preferred format — as an `AsyncStream`. Useful when
/// a caller wants tap-level data without `SFSpeechAudioBufferRecognitionRequest`
/// owning it (e.g. recording-while-transcribing, level meters, file dump for
/// debugging).
///
/// `AppleSpeechBackend` does NOT use this type. It taps the engine directly into
/// the request to avoid an extra ring buffer + format conversion. `AudioCapture`
/// is the building block for future paths: VAD, voice transform, replay-to-file.
///
/// Why a separate file: `MicrophoneSource` already exists and produces complete
/// 1-second `AudioChunk` arrays — its API is committed and downstream callers
/// depend on it. `AudioCapture` provides the orthogonal "raw streaming buffer"
/// view without breaking `MicrophoneSource`.
public actor AudioCapture {

    public enum CaptureError: Error, Sendable, CustomStringConvertible {
        case alreadyStarted
        case noInputDevice
        case engineFailed(String)
        case formatBuildFailed
        case converterFailed

        public var description: String {
            switch self {
            case .alreadyStarted:     return "audio capture already started"
            case .noInputDevice:      return "no audio input device available"
            case .engineFailed(let s): return "audio engine failed: \(s)"
            case .formatBuildFailed:  return "cannot build 16 kHz mono Float32 format"
            case .converterFailed:    return "AVAudioConverter creation failed"
            }
        }
    }

    public struct Config: Sendable {
        public var sampleRate: Double
        public var bufferSize: AVAudioFrameCount
        /// Drop-oldest backpressure threshold. When the downstream consumer
        /// falls behind by more than `bufferLimit` buffers, the oldest are
        /// dropped to keep the input thread non-blocking.
        public var bufferLimit: Int

        public init(sampleRate: Double = 16_000,
                    bufferSize: AVAudioFrameCount = 1024,
                    bufferLimit: Int = 32) {
            self.sampleRate = sampleRate
            self.bufferSize = bufferSize
            self.bufferLimit = bufferLimit
        }

        public static let `default` = Config()
    }

    private let config: Config
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var running: Bool = false

    public init(config: Config = .default) {
        self.config = config
    }

    public func start() async throws -> AsyncStream<AVAudioPCMBuffer> {
        if running { throw CaptureError.alreadyStarted }

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw CaptureError.noInputDevice
        }
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: config.sampleRate,
                                               channels: 1,
                                               interleaved: false) else {
            throw CaptureError.formatBuildFailed
        }
        // Only allocate a converter if hardware format differs — common case
        // is hw at 44.1 / 48 kHz stereo. When hw == target we skip the
        // converter entirely and pass buffers through.
        let needsConversion: Bool = hwFormat.sampleRate != targetFormat.sampleRate ||
                                    hwFormat.channelCount != targetFormat.channelCount ||
                                    hwFormat.commonFormat != targetFormat.commonFormat
        let converter: AVAudioConverter?
        if needsConversion {
            guard let c = AVAudioConverter(from: hwFormat, to: targetFormat) else {
                throw CaptureError.converterFailed
            }
            converter = c
        } else {
            converter = nil
        }

        // `.bufferingNewest(bufferLimit)`: drop oldest on overflow — backpressure
        // requirement from the spec. Audio capture must never block.
        let stream = AsyncStream<AVAudioPCMBuffer>(
            bufferingPolicy: .bufferingNewest(config.bufferLimit)
        ) { cont in
            self.continuation = cont
        }

        // Why install on hw format then convert in-tap: AVAudioEngine taps
        // accept only formats the engine routes to that node. Re-routing
        // would require a mixer node — extra latency, extra surface area.
        inputNode.installTap(onBus: 0,
                             bufferSize: config.bufferSize,
                             format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            if let converter {
                if let out = Self.convert(buffer: buffer,
                                          using: converter,
                                          targetFormat: targetFormat) {
                    Task { await self.yield(out) }
                }
            } else {
                Task { await self.yield(buffer) }
            }
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw CaptureError.engineFailed("\(error)")
        }
        running = true
        return stream
    }

    public func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }
        continuation?.finish()
        continuation = nil
        running = false
    }

    private func yield(_ buffer: AVAudioPCMBuffer) {
        continuation?.yield(buffer)
    }

    /// One-shot convert. Same shape as `MicrophoneSource.convert`; kept local
    /// rather than shared because the two callers may diverge (e.g. this one
    /// may eventually emit ints for VAD; `MicrophoneSource` stays Float32).
    private static func convert(buffer: AVAudioPCMBuffer,
                                using converter: AVAudioConverter,
                                targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: outCapacity) else {
            return nil
        }
        final class OneShotFlag { var fired = false }
        let flag = OneShotFlag()
        let inputBlock: AVAudioConverterInputBlock = { _, status in
            if flag.fired {
                status.pointee = .noDataNow
                return nil
            }
            flag.fired = true
            status.pointee = .haveData
            return buffer
        }
        var error: NSError?
        let result = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
        if result == .error || error != nil { return nil }
        return outBuffer
    }
}
