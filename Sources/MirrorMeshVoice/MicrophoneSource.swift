import Foundation
import AVFoundation
import MirrorMeshCore

/// Microphone capture. Produces 16 kHz mono Float32 `AudioChunk`s suitable for whisper.cpp.
///
/// Why AVAudioEngine over AVCaptureSession: a single tap on the input node gives us PCM
/// buffers in any AVAudioFormat we ask for, including the 16 kHz mono Float32 whisper
/// wants. AVCaptureSession would route through CMSampleBuffer + manual conversion.
public actor MicrophoneSource {
    public enum MicrophoneError: Error, Sendable {
        case permissionDenied
        case engineSetupFailed(String)
        case alreadyStarted
    }

    public struct Config: Sendable {
        public var sampleRate: Int
        public var chunkSeconds: Double

        public init(sampleRate: Int = 16_000, chunkSeconds: Double = 1.0) {
            self.sampleRate = sampleRate
            self.chunkSeconds = chunkSeconds
        }
        public static let `default` = Config()
    }

    private let config: Config
    private let engine = AVAudioEngine()
    private var continuation: AsyncStream<AudioChunk>.Continuation?
    private var pending: [Float] = []
    private var chunkSampleTarget: Int = 16_000
    private var nextChunkStartNs: UInt64 = 0
    private var running: Bool = false

    public init(config: Config = .default) {
        self.config = config
    }

    /// Start capture. Async because requesting microphone permission is async.
    /// On a headless/sandboxed environment without a microphone, the engine fails to
    /// start and `MicrophoneError.engineSetupFailed` is thrown — same UX shape as
    /// `LiveCaptureSource.start()` for camera permission denial.
    public func start() async throws -> AsyncStream<AudioChunk> {
        if running { throw MicrophoneError.alreadyStarted }
        let granted = await Self.requestPermission()
        guard granted else { throw MicrophoneError.permissionDenied }

        chunkSampleTarget = max(1, Int(Double(config.sampleRate) * config.chunkSeconds))
        nextChunkStartNs = MirrorMeshCore.hostTimeNs()

        let inputNode = engine.inputNode
        let hwFormat = inputNode.outputFormat(forBus: 0)
        guard hwFormat.sampleRate > 0 else {
            throw MicrophoneError.engineSetupFailed("input bus has zero sample rate (no mic available)")
        }
        // Why a converter: AVAudioEngine taps must use the hardware format. We resample to
        // 16 kHz mono Float32 on the audio thread before yielding chunks.
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: Double(config.sampleRate),
                                               channels: 1,
                                               interleaved: false) else {
            throw MicrophoneError.engineSetupFailed("cannot build target AVAudioFormat")
        }
        let converter = AVAudioConverter(from: hwFormat, to: targetFormat)

        let stream = AsyncStream<AudioChunk>(bufferingPolicy: .bufferingNewest(8)) { cont in
            self.continuation = cont
        }

        let bufferSize: AVAudioFrameCount = 1024
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: hwFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let converted = Self.convert(buffer: buffer,
                                         using: converter,
                                         targetFormat: targetFormat)
            guard !converted.isEmpty else { return }
            Task { await self.ingest(converted) }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw MicrophoneError.engineSetupFailed("\(error)")
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
        pending.removeAll(keepingCapacity: false)
        running = false
    }

    /// Append converted samples; emit chunks whenever we cross the target size.
    private func ingest(_ samples: [Float]) {
        pending.append(contentsOf: samples)
        while pending.count >= chunkSampleTarget {
            let slice = Array(pending.prefix(chunkSampleTarget))
            pending.removeFirst(chunkSampleTarget)
            let chunk = AudioChunk(samples: slice,
                                   sampleRate: config.sampleRate,
                                   startNs: nextChunkStartNs)
            // Advance startNs by the chunk's true duration.
            let durationNs = UInt64(config.chunkSeconds * 1_000_000_000.0)
            nextChunkStartNs &+= durationNs
            continuation?.yield(chunk)
        }
    }

    private static func requestPermission() async -> Bool {
        #if os(macOS)
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized: return true
        case .notDetermined:
            return await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    cont.resume(returning: ok)
                }
            }
        default: return false
        }
        #else
        return true
        #endif
    }

    private static func convert(buffer: AVAudioPCMBuffer,
                                using converter: AVAudioConverter?,
                                targetFormat: AVAudioFormat) -> [Float] {
        guard let converter else { return [] }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 16)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                               frameCapacity: outCapacity) else {
            return []
        }
        // Why a class box: AVAudioConverterInputBlock is non-Sendable and called once;
        // Swift 6 forbids capturing a var, so the flag lives behind a reference.
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
        guard result != .error, error == nil,
              let channelData = outBuffer.floatChannelData?[0] else {
            return []
        }
        let count = Int(outBuffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: count))
    }
}
