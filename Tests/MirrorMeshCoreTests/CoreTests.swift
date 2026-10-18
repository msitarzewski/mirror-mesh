import Testing
import Foundation
@testable import MirrorMeshCore

@Suite("MirrorMeshCore")
struct CoreTests {
    @Test func versionPresent() {
        #expect(!MirrorMeshCore.version.isEmpty)
    }

    @Test func frameIDIsMonotonic() {
        let gen = FrameIDGenerator()
        let a = gen.next()
        let b = gen.next()
        #expect(b.value == a.value + 1)
    }

    @Test func hostTimeMovesForward() {
        let t0 = MirrorMeshCore.hostTimeNs()
        Thread.sleep(forTimeInterval: 0.001)
        let t1 = MirrorMeshCore.hostTimeNs()
        #expect(t1 > t0)
    }

    @Test func histogramPercentilesAreOrdered() {
        var h = LatencyHistogram()
        for ms in stride(from: 0.1, through: 100.0, by: 0.5) {
            h.record(ms)
        }
        #expect(h.p50 <= h.p95)
        #expect(h.p95 <= h.p99)
        #expect(h.sampleCount == 200)
    }

    @Test func ringBufferDropsOldest() {
        let sink = RingBufferSink(capacity: 4)
        for i: UInt64 in 1...10 {
            sink.consume(.annotation(key: "i", value: "\(i)"))
            _ = i
        }
        let snap = sink.snapshot()
        #expect(snap.count == 4)
        #expect(sink.seenCount == 10)
    }

    @Test func stageIDIsCaseIterable() {
        #expect(StageID.allCases.contains(.capture))
        #expect(StageID.allCases.contains(.watermark))
    }
}

@Suite("GazeChannels")
struct GazeChannelsTests {
    @Test func encodeDecodeRoundTrips() {
        for (h, v) in [(Float(0), Float(0)), (0.5, -0.25), (-0.8, 0.6), (1, -1)] {
            let decoded = GazeChannels.decode(GazeChannels.encode(horizontal: h, vertical: v))
            #expect(abs(decoded.horizontal - h) < 1e-6)
            #expect(abs(decoded.vertical - v) < 1e-6)
        }
    }

    @Test func imageRightGazeIsInForLeftEyeAndOutForRightEye() {
        let c = GazeChannels.encode(horizontal: 0.7, vertical: 0)
        #expect(c[.eyeLookInLeft] == 0.7)
        #expect(c[.eyeLookOutRight] == 0.7)
        #expect(c[.eyeLookOutLeft] == 0)
        #expect(c[.eyeLookInRight] == 0)
    }

    @Test func encodeClampsAndOnlyTouchesGazeKeys() {
        let c = GazeChannels.encode(horizontal: 3, vertical: -3)
        #expect(Set(c.keys) == Set(GazeChannels.keys))
        #expect(c.values.allSatisfy { $0 >= 0 && $0 <= 1 })
    }

    @Test func landmarkFrameDefaultsToNoEyes() {
        let f = LandmarkFrame(frameID: FrameIDGenerator.shared.next(), hostTimeNs: 0, points: [],
                              confidence: 1, faceBoundingBoxNorm: .zero)
        #expect(f.eyes.isEmpty)
    }
}
