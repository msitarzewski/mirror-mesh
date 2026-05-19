import Foundation

/// Hand-stitched triangle topology for the 76-point Vision landmark schema.
///
/// The indices follow `MirrorMeshSolver.LandmarkIndex` bands:
///   0..15  silhouette (outline) — 16 pts
///   16..23 left eye ring        —  8 pts
///   24..31 right eye ring       —  8 pts
///   32..39 nose                 —  8 pts
///   40..55 mouth outer          — 16 pts
///   56..63 chin / jawline       —  8 pts
///   64..75 brows + inner mouth  — 12 pts
///
/// Stitching strategy (why not Delaunay): a hardcoded fan/strip per band is deterministic,
/// avoids a triangulation dependency, and produces a face plane that's stable across
/// landmark jitter. Bands are connected via "bridge" triangles whose vertices touch the
/// nose tip / outline so the silhouette feels filled rather than a ring of strips.
public enum MeshTopology {
    /// Triangle indices into a flat 76-point landmark array. Length is a multiple of 3.
    public static let indices: [UInt16] = buildIndices()

    /// Triangle count derived from `indices`.
    public static var triangleCount: Int { indices.count / 3 }

    /// Band membership for a given landmark index — used by tests to assert each band
    /// participates in at least one triangle. Mirrors `LandmarkIndex` ranges.
    public enum Band: CaseIterable {
        case silhouette, leftEye, rightEye, nose, mouth, chin, detail

        public func contains(_ idx: Int) -> Bool {
            switch self {
            case .silhouette: return (0..<16).contains(idx)
            case .leftEye:    return (16..<24).contains(idx)
            case .rightEye:   return (24..<32).contains(idx)
            case .nose:       return (32..<40).contains(idx)
            case .mouth:      return (40..<56).contains(idx)
            case .chin:       return (56..<64).contains(idx)
            case .detail:     return (64..<76).contains(idx)
            }
        }
    }

    private static func buildIndices() -> [UInt16] {
        var t: [UInt16] = []
        t.reserveCapacity(360)

        // Helper: append a triangle if all three indices are distinct (drop degenerates).
        func tri(_ a: Int, _ b: Int, _ c: Int) {
            guard a != b, b != c, a != c else { return }
            t.append(UInt16(a)); t.append(UInt16(b)); t.append(UInt16(c))
        }

        // Ring fan: connect consecutive points on a closed loop to a center point.
        func ringFan(start: Int, count: Int, center: Int) {
            for i in 0..<count {
                tri(center, start + i, start + ((i + 1) % count))
            }
        }

        // Ring strip: two parallel rings stitched as a quad strip.
        func ringStrip(outerStart: Int, outerCount: Int,
                       innerStart: Int, innerCount: Int) {
            // Why: rings may differ in length; pair by parametric position so the strip wraps.
            let n = max(outerCount, innerCount)
            for i in 0..<n {
                let o0 = outerStart + (i % outerCount)
                let o1 = outerStart + ((i + 1) % outerCount)
                let i0 = innerStart + (i % innerCount)
                let i1 = innerStart + ((i + 1) % innerCount)
                tri(o0, i0, o1)
                tri(o1, i0, i1)
            }
        }

        // 1) Silhouette filled as a fan around the nose tip (index 36).
        // 16 outline points form a closed loop; this gives 16 triangles that cover the
        // face plane and anchor every silhouette vertex.
        let noseTip = 36
        for i in 0..<16 {
            tri(noseTip, i, (i + 1) % 16)
        }

        // 2) Nose band stitched as a short strip from bridge to tip.
        // Indices 32..39: 32-35 are bridge (top→down), 36 tip, 37-39 nostrils/base.
        tri(32, 33, 36)
        tri(33, 34, 36)
        tri(34, 35, 36)
        tri(35, 37, 36)
        tri(37, 38, 36)
        tri(38, 39, 36)
        tri(39, 32, 36)

        // 3) Left eye ring (16..23, 8 pts) — fan around index 18 (upper) and back to 22 (lower).
        // Why two fans: prevents the centroid landing on a single ring point causing slivers.
        ringFan(start: 16, count: 8, center: 18)
        ringFan(start: 16, count: 8, center: 22)

        // 4) Right eye ring (24..31, 8 pts) — same treatment.
        ringFan(start: 24, count: 8, center: 26)
        ringFan(start: 24, count: 8, center: 30)

        // 5) Mouth outer ring (40..55, 16 pts) — fan around upper lip center (44).
        ringFan(start: 40, count: 16, center: 44)
        // Bridge the lower half to the lower-lip center so the lip area is filled.
        ringFan(start: 40, count: 16, center: 52)

        // 6) Inner mouth detail (band 64..75 contains brows + inner mouth detail).
        // Use indices 68-69, 74-75 as approximate inner-mouth corners; stitch to outer mouth.
        // Why approximate: detailRange is "best-effort" per LandmarkIndex doc; we anchor with
        // mouth corners (40, 48) and upper/lower lip centers (44, 52).
        tri(40, 68, 44)
        tri(44, 69, 48)
        tri(48, 74, 52)
        tri(52, 75, 40)

        // 7) Chin / jawline (56..63, 8 pts) — fan around chin tip (60) so the lower face
        // bridges silhouette → chin → mouth.
        let chinTip = 60
        for i in 56..<63 {
            tri(chinTip, i, i + 1)
        }
        // Connect chin band back to silhouette so the jawline isn't a free-floating fan.
        tri(56, 0, 60)
        tri(63, 15, 60)
        tri(56, 60, 52)   // chin to lower lip
        tri(63, 60, 52)

        // 8) Brow band (64..75 first half = brows) anchored to outline + eye rings.
        // Why: brows are detail that benefits from being stitched between forehead silhouette
        // and the top of each eye ring (18, 26).
        tri(64, 65, 18)
        tri(65, 66, 18)
        tri(66, 67, 18)
        tri(70, 71, 26)
        tri(71, 72, 26)
        tri(72, 73, 26)
        // Brow outer corners up to silhouette.
        tri(64, 0, 18)
        tri(67, 36, 18)   // inner brow to nose tip via upper eye
        tri(70, 36, 26)
        tri(73, 15, 26)

        // Suppress unused-helper warnings when the strip variant isn't called (kept for clarity).
        _ = ringStrip

        return t
    }
}
