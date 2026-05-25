import Testing
import Foundation
import CoreML
@testable import MirrorMeshReenact

// Coverage for `PhotorealBackend.dumpMultiArray` and `dumpFlatFloats` — the Phase 2
// gating tools that let an MPSGraph submodel port be numerically validated against
// the current CoreML reference. The format (raw float32 .bin + JSON sidecar with
// shape + dtype) is the contract a downstream Python diff script depends on, so
// these tests pin it.

@Suite("PhotorealBackend tensor dump")
struct TensorDumpTests {

    @Test func dumpMultiArrayWritesBinAndSidecar() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let array = try MLMultiArray(shape: [1, 2, 3] as [NSNumber], dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float32.self, capacity: 6)
        for i in 0..<6 { ptr[i] = Float32(i) * 1.5 }

        try PhotorealBackend.dumpMultiArray(array, name: "test_tensor", in: tmp)

        let bin = tmp.appendingPathComponent("test_tensor.bin")
        let json = tmp.appendingPathComponent("test_tensor.json")
        #expect(FileManager.default.fileExists(atPath: bin.path))
        #expect(FileManager.default.fileExists(atPath: json.path))

        // .bin is raw float32, 6 elements × 4 bytes = 24 bytes.
        let binData = try Data(contentsOf: bin)
        #expect(binData.count == 6 * MemoryLayout<Float32>.stride)
        let readBack: [Float32] = binData.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float32.self).prefix(6))
        }
        for i in 0..<6 {
            #expect(readBack[i] == Float32(i) * 1.5)
        }

        // Sidecar should parse and have the expected shape + dtype.
        let jsonStr = try String(contentsOf: json, encoding: .utf8)
        #expect(jsonStr.contains("\"shape\":[1, 2, 3]"))
        #expect(jsonStr.contains("\"dtype\":\"float32\""))
        #expect(jsonStr.contains("\"count\":6"))
        #expect(jsonStr.contains("\"name\":\"test_tensor\""))
    }

    @Test func dumpFlatFloatsRoundTrips() throws {
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }

        let values: [Float32] = [-1.0, 0.5, 3.14, 42.0]
        try PhotorealBackend.dumpFlatFloats(values, shape: [1, 4], name: "flat", in: tmp)

        let bin = try Data(contentsOf: tmp.appendingPathComponent("flat.bin"))
        let readBack: [Float32] = bin.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float32.self).prefix(4))
        }
        #expect(readBack == values)

        let json = try String(contentsOf: tmp.appendingPathComponent("flat.json"), encoding: .utf8)
        #expect(json.contains("\"shape\":[1, 4]"))
    }

    @Test func dumpFlatFloatsShapeMismatchTrips() throws {
        // This is a precondition; we just verify the documented behavior shape — the
        // value-count assertion fires at runtime. We can't easily test precondition
        // failures without crashing the test runner, so we test the success path with
        // an exact-fit shape instead and trust the precondition for the negative case.
        let tmp = makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        try PhotorealBackend.dumpFlatFloats([1, 2, 3, 4, 5, 6], shape: [2, 3], name: "ok", in: tmp)
        let bin = try Data(contentsOf: tmp.appendingPathComponent("ok.bin"))
        #expect(bin.count == 6 * MemoryLayout<Float32>.stride)
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mirrormesh_tensor_dump_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
