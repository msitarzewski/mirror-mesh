import Testing
import Foundation
import simd
@testable import MirrorMeshReenact

@Suite("StylizedHead blendshape solver")
struct StylizedHeadBlendshapeTests {

    // MARK: - Synthetic landmark builder
    //
    // Mirrors the 76-point layout produced by `SyntheticLandmarkExtractor` (used as the canonical
    // schema across the project). The builder takes per-feature offsets so each test can perturb
    // exactly one feature and assert the right coefficient responds.

    struct LandmarkOverride {
        var mouthOpen: Float = 0       // extra vertical opening of the mouth (in normalized units)
        var mouthWidthDelta: Float = 0 // additive change to mouth horizontal extent
        var leftCornerLift: Float = 0  // negative y delta to the leftmost mouth point
        var rightCornerLift: Float = 0 // negative y delta to the rightmost mouth point
        var browLift: Float = 0        // both brows up by this amount (positive = brow higher)
        var leftBrowDrop: Float = 0    // left brow drops by this amount (positive = lower)
        var eyeClose: Float = 0        // collapse eye vertical extent by this fraction (0..1)
        var headYaw: Float = 0         // rotates everything around the face center in image plane
    }

    static func synthesizeLandmarks(_ o: LandmarkOverride = .init()) -> [SIMD2<Float>] {
        let cx: Float = 0.5
        let cy: Float = 0.5
        let s: Float = 0.25
        let eyeY = cy - s / 3
        let mouthOpenBase = (s / 6) * 0.5
        let mouthOpen = mouthOpenBase + o.mouthOpen

        var pts: [SIMD2<Float>] = []
        // 0..15: silhouette
        for i in 0..<16 {
            let theta = (Double(i) / 15.0) * .pi - .pi / 2
            pts.append(SIMD2(
                cx + Float(cos(theta)) * (s * 0.9),
                cy + Float(sin(theta)) * (s * 1.1)
            ))
        }
        // 16..23: left eye ring (collapsed if eyeClose)
        let leftEye = SIMD2(cx - s / 3, eyeY)
        let eyeYRadius = (s / 18) * (1 - o.eyeClose)
        for i in 0..<8 {
            let theta = Double(i) / 7.0 * 2 * .pi
            pts.append(SIMD2(
                leftEye.x + Float(cos(theta)) * s / 14,
                leftEye.y + Float(sin(theta)) * eyeYRadius
            ))
        }
        // 24..31: right eye ring (also affected so jawOpen test stays clean)
        let rightEye = SIMD2(cx + s / 3, eyeY)
        for i in 0..<8 {
            let theta = Double(i) / 7.0 * 2 * .pi
            pts.append(SIMD2(
                rightEye.x + Float(cos(theta)) * s / 14,
                rightEye.y + Float(sin(theta)) * eyeYRadius
            ))
        }
        // 32..39: nose
        for i in 0..<8 {
            pts.append(SIMD2(cx + Float(i - 4) * s / 80, cy + Float(i) * s / 80))
        }
        // 40..55: mouth ring with overrides
        for i in 0..<16 {
            let theta = Double(i) / 15.0 * 2 * .pi
            let baseX = cx + Float(cos(theta)) * (s / 3 + o.mouthWidthDelta * 0.5)
            let baseY = cy + s / 3 + Float(sin(theta)) * mouthOpen
            pts.append(SIMD2(baseX, baseY))
        }
        // Apply leftCornerLift / rightCornerLift: find the leftmost & rightmost mouth-ring
        // points and lift them (smaller y).
        if o.leftCornerLift != 0 || o.rightCornerLift != 0 {
            var leftIdx = 40, rightIdx = 40
            for i in 40..<56 {
                if pts[i].x < pts[leftIdx].x { leftIdx = i }
                if pts[i].x > pts[rightIdx].x { rightIdx = i }
            }
            pts[leftIdx].y -= o.leftCornerLift
            pts[rightIdx].y -= o.rightCornerLift
        }
        // 56..63: chin / jaw — push down by mouthOpen so jawOpen ratio reflects opening.
        for i in 0..<8 {
            let theta = (Double(i) / 7.0) * .pi
            pts.append(SIMD2(
                cx + Float(cos(theta + .pi)) * s * 0.8,
                cy + s * 0.5 + Float(sin(theta + .pi)) * s * 0.2 + o.mouthOpen
            ))
        }
        // 64..67: left brow (default to brow gap ~0.05). browLift moves both up; leftBrowDrop
        // moves left down separately.
        for i in 0..<4 {
            let dy = -o.browLift + o.leftBrowDrop
            pts.append(SIMD2(cx - s / 3 + Float(i) * 0.04 - 0.06, eyeY - s / 6 + dy))
        }
        // 68..71: right brow
        for i in 0..<4 {
            let dy = -o.browLift
            pts.append(SIMD2(cx + s / 3 + Float(i) * 0.04 - 0.06, eyeY - s / 6 + dy))
        }
        // 72..75: inner mouth detail
        for i in 0..<4 {
            pts.append(SIMD2(cx, cy + s / 3 + Float(i) * s / 80))
        }

        // Apply headYaw by rotating all points around (cx, cy). This shifts nose vs eye midline.
        if o.headYaw != 0 {
            let c = cos(o.headYaw)
            let s_ = sin(o.headYaw)
            for i in 0..<pts.count {
                let dx = pts[i].x - cx
                let dy = pts[i].y - cy
                pts[i] = SIMD2(cx + dx * c - dy * s_, cy + dx * s_ + dy * c)
            }
        }
        return pts
    }

    // MARK: - Coefficient tests

    @Test func restPoseProducesLowJawOpen() {
        let solver = LandmarkSolver()
        let coefs = solver.solve(landmarks: Self.synthesizeLandmarks())
        let jawOpen = coefs[.jawOpen] ?? -1
        #expect(jawOpen >= 0 && jawOpen <= 0.3,
                "rest pose should have low jaw-open coefficient, got \(jawOpen)")
    }

    @Test func jawOpenRespondsToMouthGap() {
        let solver = LandmarkSolver()
        let closed = solver.solve(landmarks: Self.synthesizeLandmarks())
        let open   = solver.solve(landmarks: Self.synthesizeLandmarks(.init(mouthOpen: 0.06)))
        let cj = closed[.jawOpen] ?? 0
        let oj = open[.jawOpen] ?? 0
        #expect(oj > cj, "jawOpen should rise when mouth opens (closed=\(cj), open=\(oj))")
    }

    @Test func smileLRespondsToLeftCornerLift() {
        let solver = LandmarkSolver()
        let neutral = solver.solve(landmarks: Self.synthesizeLandmarks())
        let smiling = solver.solve(landmarks: Self.synthesizeLandmarks(.init(leftCornerLift: 0.015)))
        let baseL  = neutral[.smileL] ?? 0
        let liftL  = smiling[.smileL] ?? 0
        let baseR  = neutral[.smileR] ?? 0
        let liftR  = smiling[.smileR] ?? 0
        #expect(liftL > baseL, "smileL should rise when left mouth corner lifts (\(baseL) → \(liftL))")
        // Right side should be largely unchanged since we only moved the left corner.
        #expect(abs(liftR - baseR) < 0.20, "smileR should be ~unchanged when only left corner lifts")
    }

    @Test func smileRRespondsToRightCornerLift() {
        let solver = LandmarkSolver()
        let neutral = solver.solve(landmarks: Self.synthesizeLandmarks())
        let smiling = solver.solve(landmarks: Self.synthesizeLandmarks(.init(rightCornerLift: 0.015)))
        let liftR = smiling[.smileR] ?? 0
        let baseR = neutral[.smileR] ?? 0
        #expect(liftR > baseR, "smileR should rise when right mouth corner lifts (\(baseR) → \(liftR))")
    }

    @Test func browUpRespondsToBrowLift() {
        let solver = LandmarkSolver()
        let neutral = solver.solve(landmarks: Self.synthesizeLandmarks())
        let raised  = solver.solve(landmarks: Self.synthesizeLandmarks(.init(browLift: 0.03)))
        for shape in [StylizedBlendshape.browUpL, .browUpR] {
            let n = neutral[shape] ?? 0
            let r = raised[shape] ?? 0
            #expect(r > n, "\(shape) should rise on browLift (\(n) → \(r))")
        }
    }

    @Test func browDownLRespondsToLeftBrowDrop() {
        let solver = LandmarkSolver()
        let neutral = solver.solve(landmarks: Self.synthesizeLandmarks())
        let frowning = solver.solve(landmarks: Self.synthesizeLandmarks(.init(leftBrowDrop: 0.03)))
        let baseL = neutral[.browDownL] ?? 0
        let frownL = frowning[.browDownL] ?? 0
        #expect(frownL > baseL, "browDownL should rise on leftBrowDrop (\(baseL) → \(frownL))")
    }

    @Test func eyeCloseRespondsToEyeCollapse() {
        let solver = LandmarkSolver()
        let neutral = solver.solve(landmarks: Self.synthesizeLandmarks())
        let closed  = solver.solve(landmarks: Self.synthesizeLandmarks(.init(eyeClose: 0.85)))
        for shape in [StylizedBlendshape.eyeCloseL, .eyeCloseR] {
            let n = neutral[shape] ?? 0
            let c = closed[shape] ?? 0
            #expect(c > n, "\(shape) should rise as eye collapses (\(n) → \(c))")
        }
    }

    @Test func mouthPuckerRespondsToWidthDecrease() {
        let solver = LandmarkSolver()
        let neutral = solver.solve(landmarks: Self.synthesizeLandmarks())
        let pursed  = solver.solve(landmarks: Self.synthesizeLandmarks(.init(mouthWidthDelta: -0.06)))
        let baseP = neutral[.mouthPucker] ?? 0
        let pP    = pursed[.mouthPucker] ?? 0
        #expect(pP > baseP, "mouthPucker should rise as mouth narrows (\(baseP) → \(pP))")
    }

    @Test func mouthWideRespondsToWidthIncrease() {
        let solver = LandmarkSolver()
        let neutral = solver.solve(landmarks: Self.synthesizeLandmarks())
        let wide    = solver.solve(landmarks: Self.synthesizeLandmarks(.init(mouthWidthDelta: 0.05)))
        let baseW = neutral[.mouthWide] ?? 0
        let wW    = wide[.mouthWide] ?? 0
        #expect(wW > baseW, "mouthWide should rise as mouth widens (\(baseW) → \(wW))")
    }

    @Test func headYawRespondsToHeadRotation() {
        let solver = LandmarkSolver()
        let centered = solver.solve(landmarks: Self.synthesizeLandmarks())
        let yawed    = solver.solve(landmarks: Self.synthesizeLandmarks(.init(headYaw: 0.15)))
        let baseYaw = centered[.headYaw] ?? 0
        let newYaw  = yawed[.headYaw] ?? 0
        #expect(abs(newYaw) > abs(baseYaw) + 0.05,
                "headYaw magnitude should rise as head rotates (\(baseYaw) → \(newYaw))")
    }

    // MARK: - Clamping tests

    @Test func allCoefficientsClampToValidRange() {
        let solver = LandmarkSolver()
        // Wildly perturbed landmarks should still produce coefficients in [-1, 1] (pose) or [0, 1].
        let extreme = Self.synthesizeLandmarks(.init(
            mouthOpen: 0.30,
            mouthWidthDelta: 0.20,
            leftCornerLift: 0.10,
            rightCornerLift: 0.10,
            browLift: 0.20,
            leftBrowDrop: 0.20,
            eyeClose: 1.0,
            headYaw: 1.5
        ))
        let coefs = solver.solve(landmarks: extreme)
        for (key, value) in coefs {
            switch key {
            case .headYaw, .headPitch, .headRoll, .eyeLookHorizontal, .eyeLookVertical:
                #expect(value >= -1.0 && value <= 1.0,
                        "\(key) out of [-1, 1]: \(value)")
            default:
                #expect(value >= 0.0 && value <= 1.0,
                        "\(key) out of [0, 1]: \(value)")
            }
        }
    }

    @Test func fewerThan76PointsReturnsZeros() {
        let solver = LandmarkSolver()
        let coefs = solver.solve(landmarks: Array(repeating: SIMD2<Float>(0.5, 0.5), count: 30))
        for (_, value) in coefs {
            #expect(value == 0)
        }
    }

    // MARK: - Mesh deformation tests

    @Test func meshDeformsWhenJawOpen() {
        let model = StylizedHeadModel()
        let rest = model.baseVertices
        let opened = model.deform(coefficients: [.jawOpen: 1.0])
        #expect(rest.count == opened.count)
        // Some vertices should have moved.
        var moved = 0
        for i in 0..<rest.count where simd_distance(rest[i], opened[i]) > 1e-6 {
            moved += 1
        }
        #expect(moved > 0, "jawOpen=1 should move at least some vertices")
        // The vertex with the largest downward delta should be in the lower-front quadrant.
        var maxDownIdx = 0
        var maxDown: Float = 0
        for i in 0..<rest.count {
            let dy = rest[i].y - opened[i].y   // positive = moved down (lower y)
            if dy > maxDown { maxDown = dy; maxDownIdx = i }
        }
        let v = rest[maxDownIdx]
        #expect(v.y < 0, "max-down vertex should be in lower half of head")
        #expect(v.z > 0, "max-down vertex should be in front of head")
    }

    @Test func meshDeformsAreSymmetricForSymmetricShapes() {
        let model = StylizedHeadModel()
        // Apply equal smileL and smileR — the resulting mesh should be near-mirror-symmetric in X.
        let deformed = model.deform(coefficients: [.smileL: 1.0, .smileR: 1.0])
        var asym: Float = 0
        for i in 0..<deformed.count {
            // Find a vertex with mirrored X; tolerate small numeric jitter.
            let v = deformed[i]
            // Look for closest mirror by base position to avoid index-dependency.
            var bestDist: Float = .infinity
            var bestY: Float = 0
            var bestZ: Float = 0
            for j in 0..<deformed.count {
                let w = deformed[j]
                let d = abs(w.x - -v.x) + abs(w.y - v.y) + abs(w.z - v.z)
                if d < bestDist {
                    bestDist = d
                    bestY = w.y
                    bestZ = w.z
                }
            }
            asym += abs(v.y - bestY) + abs(v.z - bestZ)
        }
        // Loose threshold — procedural mesh isn't perfectly symmetric due to slice phasing, but
        // the deformations themselves should be.
        #expect(asym / Float(deformed.count) < 0.10,
                "symmetric shapes should produce near-symmetric mesh, asym/n=\(asym / Float(deformed.count))")
    }

    @Test func meshNormalsAreUnitLength() {
        let model = StylizedHeadModel()
        let verts = model.deform(coefficients: [.smileL: 0.4, .jawOpen: 0.3])
        let normals = model.computeNormals(vertices: verts)
        #expect(normals.count == verts.count)
        for n in normals {
            let len = simd_length(n)
            #expect(abs(len - 1.0) < 1e-3, "normal not unit length: \(len)")
        }
    }

    @Test func meshHasExpectedTopology() {
        let model = StylizedHeadModel()
        #expect(model.baseVertices.count == StylizedHeadModel.expectedVertexCount)
        #expect(model.indices.count % 3 == 0)
        // Every blendshape's delta array matches base count.
        for shape in StylizedBlendshape.allCases {
            let deltas = model.blendshapes[shape]
            #expect(deltas?.count == model.baseVertices.count,
                    "blendshape \(shape) deltas count mismatch")
        }
    }
}
