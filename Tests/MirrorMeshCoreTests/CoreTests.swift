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
