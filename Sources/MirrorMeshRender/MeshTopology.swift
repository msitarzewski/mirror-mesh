import Foundation
import simd

/// Triangle topology for the 76-point Vision landmark schema.
///
/// **Strategy**: Delaunay triangulation computed at startup from a canonical neutral-pose
/// reference layout of the 76 landmarks. This gives a topologically sound mesh (no triangles
/// crossing face boundaries) that we then apply at runtime as a fixed index list against the
/// per-frame landmark cloud.
///
/// Why Delaunay over hand-stitched fans:
/// - Hand-stitched bands created visible artifacts in filled rendering — triangles whose
///   winding crossed the nose or jaw made the mesh look like a fractured sticker.
/// - Delaunay over the reference layout produces a single coherent triangulation that maps
///   1:1 to per-frame landmark positions. No bridges, no overlaps, no cross-band cheats.
///
/// **Implementation**: Bowyer-Watson incremental Delaunay (~80 LOC, no external deps).
/// Computed once at process start. Triangles whose three vertices span > 70% of the
/// face bounding box are dropped — those are spurious "boundary" triangles a Delaunay
/// produces along the convex hull that don't represent actual facial geometry.
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

    // MARK: - Reference layout

    /// Approximate neutral-pose positions for the 76 landmarks in normalized [0, 1] image
    /// space (top-left origin). Used only to compute the triangulation; per-frame rendering
    /// reads the actual landmark cloud.
    ///
    /// Values are derived from the synthetic landmark layout in
    /// `SyntheticLandmarkExtractor.swift` — a face centered at (0.5, 0.5) with eyes at 0.4y,
    /// mouth at 0.62y, etc. Close enough to a real face that Delaunay produces a sane mesh.
    static let referenceLayout: [SIMD2<Float>] = {
        var pts: [SIMD2<Float>] = Array(repeating: SIMD2(0.5, 0.5), count: 76)
        let cx: Float = 0.5
        let cy: Float = 0.5
        let s: Float = 0.25

        // 0..15: silhouette ring around face
        for i in 0..<16 {
            let theta = Double(i) / 15.0 * 2 * .pi
            pts[i] = SIMD2(
                cx + Float(cos(theta)) * s * 0.95,
                cy + Float(sin(theta)) * s * 1.15
            )
        }
        // 16..23: left eye ring
        let leftEye = SIMD2(cx - s / 3, cy - s / 3)
        for i in 0..<8 {
            let theta = Double(i) / 7.0 * 2 * .pi
            pts[16 + i] = SIMD2(
                leftEye.x + Float(cos(theta)) * s / 14,
                leftEye.y + Float(sin(theta)) * s / 18
            )
        }
        // 24..31: right eye ring
        let rightEye = SIMD2(cx + s / 3, cy - s / 3)
        for i in 0..<8 {
            let theta = Double(i) / 7.0 * 2 * .pi
            pts[24 + i] = SIMD2(
                rightEye.x + Float(cos(theta)) * s / 14,
                rightEye.y + Float(sin(theta)) * s / 18
            )
        }
        // 32..39: nose
        for i in 0..<8 {
            pts[32 + i] = SIMD2(cx + Float(i - 4) * s / 80, cy + Float(i) * s / 80)
        }
        // 40..55: mouth outer ring
        for i in 0..<16 {
            let theta = Double(i) / 15.0 * 2 * .pi
            pts[40 + i] = SIMD2(
                cx + Float(cos(theta)) * s / 3,
                cy + s / 3 + Float(sin(theta)) * s / 12
            )
        }
        // 56..63: chin / jawline
        for i in 0..<8 {
            let theta = (Double(i) / 7.0) * .pi
            pts[56 + i] = SIMD2(
                cx + Float(cos(theta + .pi)) * s * 0.7,
                cy + s * 0.5 + Float(sin(theta + .pi)) * s * 0.2
            )
        }
        // 64..67 left brow, 68..71 right brow, 72..75 inner mouth detail
        for i in 0..<4 {
            pts[64 + i] = SIMD2(cx - s / 3 + Float(i) * 0.04 - 0.06, cy - s / 3 - s / 6)
            pts[68 + i] = SIMD2(cx + s / 3 + Float(i) * 0.04 - 0.06, cy - s / 3 - s / 6)
            pts[72 + i] = SIMD2(cx, cy + s / 3 + Float(i) * s / 80)
        }
        return pts
    }()

    // MARK: - Triangulation

    private static func buildIndices() -> [UInt16] {
        let pts = referenceLayout
        var tris = bowyerWatson(points: pts)

        // Drop spurious convex-hull triangles whose longest edge spans more than 65% of the
        // bounding diagonal of the point set. These are the "stretched" triangles a Delaunay
        // produces around the perimeter and they don't represent real facial geometry.
        let bbox = bounds(pts)
        let diag = simd_distance(bbox.minP, bbox.maxP)
        let maxEdge = diag * 0.65
        tris = tris.filter { tri in
            let a = pts[Int(tri.0)], b = pts[Int(tri.1)], c = pts[Int(tri.2)]
            let ab = simd_distance(a, b)
            let bc = simd_distance(b, c)
            let ca = simd_distance(c, a)
            return ab < maxEdge && bc < maxEdge && ca < maxEdge
        }

        // Flatten to indices.
        var out: [UInt16] = []
        out.reserveCapacity(tris.count * 3)
        for t in tris {
            out.append(t.0); out.append(t.1); out.append(t.2)
        }
        return out
    }

    // MARK: - Bowyer-Watson Delaunay

    private static func bowyerWatson(points: [SIMD2<Float>]) -> [(UInt16, UInt16, UInt16)] {
        // Add a super-triangle that contains all points; remove it at the end.
        let bbox = bounds(points)
        let dx = bbox.maxP.x - bbox.minP.x
        let dy = bbox.maxP.y - bbox.minP.y
        let dmax = max(dx, dy)
        let midX = (bbox.minP.x + bbox.maxP.x) / 2
        let midY = (bbox.minP.y + bbox.maxP.y) / 2
        // Super-triangle vertices at indices N, N+1, N+2.
        let n = UInt16(points.count)
        var allPoints = points
        allPoints.append(SIMD2(midX - 20 * dmax, midY - dmax))
        allPoints.append(SIMD2(midX, midY + 20 * dmax))
        allPoints.append(SIMD2(midX + 20 * dmax, midY - dmax))

        var triangles: [(UInt16, UInt16, UInt16)] = [(n, n + 1, n + 2)]

        for pIdx in 0..<UInt16(points.count) {
            let p = allPoints[Int(pIdx)]
            // Find all triangles whose circumcircle contains p — "bad" triangles.
            var bad: [(UInt16, UInt16, UInt16)] = []
            triangles.removeAll { tri in
                let inside = inCircumcircle(
                    p,
                    a: allPoints[Int(tri.0)],
                    b: allPoints[Int(tri.1)],
                    c: allPoints[Int(tri.2)]
                )
                if inside { bad.append(tri) }
                return inside
            }

            // Find the boundary of the polygonal hole — edges that appear once across all bad triangles.
            var edgeCount: [Edge: Int] = [:]
            for t in bad {
                let edges: [Edge] = [
                    Edge(t.0, t.1),
                    Edge(t.1, t.2),
                    Edge(t.2, t.0),
                ]
                for e in edges { edgeCount[e, default: 0] += 1 }
            }
            for (edge, count) in edgeCount where count == 1 {
                triangles.append((edge.a, edge.b, pIdx))
            }
        }

        // Remove triangles touching the super-triangle vertices.
        return triangles.filter { tri in
            tri.0 < n && tri.1 < n && tri.2 < n
        }
    }

    private struct Edge: Hashable {
        let a: UInt16, b: UInt16
        init(_ x: UInt16, _ y: UInt16) {
            // Undirected: canonicalize so (3,5) == (5,3).
            self.a = min(x, y); self.b = max(x, y)
        }
    }

    private static func inCircumcircle(_ p: SIMD2<Float>,
                                       a: SIMD2<Float>,
                                       b: SIMD2<Float>,
                                       c: SIMD2<Float>) -> Bool {
        // Orientation-agnostic circumcircle check: explicitly compute the circumcenter and
        // radius, then test distance. The determinant form requires consistent winding which
        // is awkward in Y-down image space; this version is bullet-proof.
        let ax = Double(a.x), ay = Double(a.y)
        let bx = Double(b.x), by = Double(b.y)
        let cx = Double(c.x), cy = Double(c.y)
        let d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        if abs(d) < 1e-12 { return false }  // degenerate (collinear)
        let aSq = ax * ax + ay * ay
        let bSq = bx * bx + by * by
        let cSq = cx * cx + cy * cy
        let ux = (aSq * (by - cy) + bSq * (cy - ay) + cSq * (ay - by)) / d
        let uy = (aSq * (cx - bx) + bSq * (ax - cx) + cSq * (bx - ax)) / d
        let dx = Double(p.x) - ux
        let dy = Double(p.y) - uy
        let rSqA = (ax - ux) * (ax - ux) + (ay - uy) * (ay - uy)
        return dx * dx + dy * dy < rSqA - 1e-9  // strict; -epsilon for numerical safety
    }

    private static func bounds(_ pts: [SIMD2<Float>]) -> (minP: SIMD2<Float>, maxP: SIMD2<Float>) {
        var minP = SIMD2<Float>(Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude)
        var maxP = SIMD2<Float>(-Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude)
        for p in pts {
            minP = simd_min(minP, p)
            maxP = simd_max(maxP, p)
        }
        return (minP, maxP)
    }
}
