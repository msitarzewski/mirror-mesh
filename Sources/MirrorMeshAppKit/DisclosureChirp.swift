import Foundation
import AVFoundation

// M59 — audible disclosure chirp. Plays once per session start so the operator (and anyone
// within earshot) gets an unambiguous auditory cue that a synthetic-video session is starting.
// Pairs with the visible watermark badge and the manifest's chirp_schedule (v0.7.0 lands the
// recurring schedule; v0.6.0 ships the start-of-session ping).
//
// Why ascending two-tone (A4 → E5):
//   • A4 (440 Hz) and E5 (659.25 Hz) form a perfect fifth — culturally recognized as "starting"
//     or "alert" without sounding alarming. NSAccessibility ding-style.
//   • 250 ms total (125 ms per tone, plus a tiny crossfade) — long enough to register, short
//     enough to not be annoying when the session restarts.
//   • -18 dBFS peak (~0.125 amplitude) — audible but not jarring on default system volume.
//
// R2 / R12: in release builds the chirp is locked on. The settings UI hides the toggle in
// release — same shape as `watermarkLockedInRelease`. Debug builds expose the toggle so
// developers running 100 iterations don't lose their minds.

/// Synthesizes and plays a short ascending two-tone "chirp" via AVAudioEngine. One instance
/// per process is fine — the engine is reused across `playChirp()` calls.
public final class DisclosureChirp: @unchecked Sendable {

    /// Frequencies for the two tones, in Hz. A4 → E5 — a perfect fifth.
    private let f1: Float = 440.00     // A4
    private let f2: Float = 659.25     // E5
    /// Total duration in seconds; split evenly between the two tones with a short crossfade.
    private let totalSeconds: Float = 0.25
    /// Peak amplitude — keep well below 1.0 to avoid clipping and to read as "tasteful".
    private let peakAmplitude: Float = 0.125
    /// Engine sample rate — 48 kHz matches what AVAudioEngine prefers on modern macs.
    private let sampleRate: Float = 48_000

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// Guards against the engine being started twice if `playChirp()` is hit on a hot loop.
    private var engineStarted = false
    private let lock = NSLock()

    public init() {}

    /// Synthesize the chirp and schedule it on the audio output. Idempotent and re-entrant —
    /// repeated calls schedule additional buffers behind the first. Failures (no audio
    /// output, permission, etc.) are swallowed — disclosure is best-effort audio, never a
    /// reason to block the pipeline.
    public func playChirp() {
        lock.lock()
        defer { lock.unlock() }

        let format = AVAudioFormat(
            standardFormatWithSampleRate: Double(sampleRate),
            channels: 1
        )
        guard let format else { return }

        if !engineStarted {
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
            } catch {
                // Audio start failed (no output device, etc.). Disclosure-by-audio is
                // best-effort — the visible watermark + manifest carry the same signal.
                return
            }
            engineStarted = true
        }

        guard let buffer = renderBuffer(format: format) else { return }
        player.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Render a PCM buffer containing the two-tone chirp. Done in software (not via
    /// `AVAudioSourceNode`) because:
    ///   1. The chirp is a one-shot — a buffer is the natural primitive.
    ///   2. Buffer playback is trivial to schedule and stops itself; we don't need a node
    ///      that produces samples forever.
    ///   3. Easier to unit-test the synthesis function (`renderSamples`) without an engine.
    private func renderBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(totalSeconds * sampleRate)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let chan = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = frameCount

        let samples = Self.renderSamples(
            count: Int(frameCount),
            sampleRate: sampleRate,
            f1: f1, f2: f2,
            peakAmplitude: peakAmplitude
        )
        for i in 0..<samples.count {
            chan[i] = samples[i]
        }
        return buffer
    }

    /// Pure-function sample synthesizer. Exposed `internal` so tests can verify the shape
    /// without standing up an AVAudioEngine (which doesn't run in many CI environments).
    static func renderSamples(
        count: Int,
        sampleRate: Float,
        f1: Float,
        f2: Float,
        peakAmplitude: Float
    ) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        guard count > 0 else { return out }

        let crossfadeFraction: Float = 0.15     // 15% of total length is a smooth A4→E5 ramp
        let crossfadeStart = Float(count) * (0.5 - crossfadeFraction / 2)
        let crossfadeEnd   = Float(count) * (0.5 + crossfadeFraction / 2)

        // 5 ms attack / 20 ms release envelope to avoid pops at start/end.
        let attackSamples  = Float(sampleRate) * 0.005
        let releaseSamples = Float(sampleRate) * 0.020
        let endIdx = Float(count - 1)

        for i in 0..<count {
            let fi = Float(i)
            let t = fi / sampleRate
            // Crossfade weight w1→0 as we cross the midpoint.
            let w1: Float
            if fi < crossfadeStart {
                w1 = 1
            } else if fi > crossfadeEnd {
                w1 = 0
            } else {
                let p = (fi - crossfadeStart) / (crossfadeEnd - crossfadeStart)
                // smoothstep for ear-friendly transition.
                w1 = 1 - (p * p * (3 - 2 * p))
            }
            let w2: Float = 1 - w1

            let s1 = sinf(2 * .pi * f1 * t)
            let s2 = sinf(2 * .pi * f2 * t)
            var sample = (w1 * s1 + w2 * s2) * peakAmplitude

            // Attack ramp
            if fi < attackSamples {
                sample *= fi / attackSamples
            }
            // Release ramp
            let distFromEnd = endIdx - fi
            if distFromEnd < releaseSamples {
                sample *= max(0, distFromEnd / releaseSamples)
            }
            out[i] = sample
        }
        return out
    }
}
