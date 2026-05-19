import Foundation

/// A short slice of mono Float32 audio at a known sample rate. Matches whisper.cpp's
/// native input shape so a chunk can be forwarded with zero conversion.
///
/// Why 16 kHz mono Float32: whisper.cpp's `whisper_full(...)` expects exactly this.
/// Any other rate or channel layout costs a resample on every chunk.
public struct AudioChunk: Sendable {
    public let samples: [Float]
    public let sampleRate: Int
    public let startNs: UInt64

    public init(samples: [Float], sampleRate: Int, startNs: UInt64) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.startNs = startNs
    }

    /// Duration of the chunk in seconds.
    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }
}
