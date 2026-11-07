import Foundation
import simd

public struct Pixel: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct Ray3: Equatable, Sendable {
    public var origin: SIMD3<Double>
    public var direction: SIMD3<Double>
    public init(origin: SIMD3<Double>, direction: SIMD3<Double>) {
        self.origin = origin
        self.direction = simd_normalize(direction)
    }

    /// Perpendicular distance from a point to this ray's line.
    public func distance(to p: SIMD3<Double>) -> Double {
        let w = p - origin
        return simd_length(w - simd_dot(w, direction) * direction)
    }
}

/// An ARKit camera pose (camera-to-world transform). ARKit's camera looks down its -Z axis
/// with +Y up; in the native landscape image, +x pixels run along camera +X and +y pixels along camera -Y.
public struct CameraPose: Codable, Equatable, Sendable {
    /// Column-major 4×4.
    public var columns: [Double]

    public init(_ m: simd_double4x4) {
        columns = [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    public init(position: SIMD3<Double>, yawDegrees: Double = 0) {
        // Camera looking along world -Z rotated about +Y by yaw.
        let a = RangeMath.radians(yawDegrees)
        let m = simd_double4x4(columns: (SIMD4(cos(a), 0, -sin(a), 0), SIMD4(0, 1, 0, 0),
                                         SIMD4(sin(a), 0, cos(a), 0), SIMD4(position, 1)))
        self.init(m)
    }

    public var matrix: simd_double4x4 {
        let c = columns
        return simd_double4x4(columns: (SIMD4(c[0], c[1], c[2], c[3]), SIMD4(c[4], c[5], c[6], c[7]),
                                        SIMD4(c[8], c[9], c[10], c[11]), SIMD4(c[12], c[13], c[14], c[15])))
    }

    public var position: SIMD3<Double> { SIMD3(columns[12], columns[13], columns[14]) }

    /// World-space ray through a pixel of the camera's native image.
    public func ray(through p: Pixel, intrinsics k: Intrinsics) -> Ray3 {
        let cam = SIMD3((p.x - k.cx) / k.fx, -(p.y - k.cy) / k.fy, -1.0)
        let m = matrix
        let r = simd_double3x3(columns: (SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z),
                                         SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z),
                                         SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)))
        return Ray3(origin: position, direction: r * cam)
    }

    /// Pixel where a world point lands (for tests and overlays). Nil if behind the camera.
    public func project(_ world: SIMD3<Double>, intrinsics k: Intrinsics) -> Pixel? {
        let local = simd_inverse(matrix) * SIMD4(world, 1)
        guard local.z < 0 else { return nil }
        return Pixel(x: k.cx + k.fx * (local.x / -local.z), y: k.cy - k.fy * (local.y / -local.z))
    }
}

/// One photo of the pole: where the camera was and where the tip and base were marked.
public struct PoleSighting: Codable, Identifiable, Equatable, Sendable {
    public var id = UUID()
    public var pose: CameraPose
    public var intrinsics: Intrinsics
    public var tip: Pixel
    public var base: Pixel

    public init(pose: CameraPose, intrinsics: Intrinsics, tip: Pixel, base: Pixel) {
        self.pose = pose; self.intrinsics = intrinsics; self.tip = tip; self.base = base
    }

    public var tipRay: Ray3 { pose.ray(through: tip, intrinsics: intrinsics) }
    public var baseRay: Ray3 { pose.ray(through: base, intrinsics: intrinsics) }
}

/// Where the pole's base is, fused from every photo's tip and base rays.
public struct PoleFix: Sendable {
    public var base: SIMD3<Double>
    public var covariance: simd_double3x3
    public var used: [UUID]
    public var dropped: [UUID]
    /// Mean angular miss of each photo's two rays, in degrees.
    public var residualDegrees: [UUID: Double]
}

/// Fuses size ranging and triangulation in one least-squares solve.
///
/// The pole is vertical with known height H, so its base B is the only unknown (3 numbers).
/// Every base ray should pass through B and every tip ray through B + H·up. Minimising the
/// squared perpendicular distance to all rays is linear in B. One photo already pins B
/// (that is size ranging); more photos from different spots add triangulation.
public enum PoleSolver {
    public static let up = SIMD3<Double>(0, 1, 0)

    static func projector(_ d: SIMD3<Double>) -> simd_double3x3 {
        let outer = simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))
        return matrix_identity_double3x3 - outer
    }

    /// - Parameters:
    ///   - pixelSigma: expected marking error in pixels, used to weight rays and size the covariance.
    ///   - dropOutliers: with 3+ photos, drop one photo whose miss is far above the rest.
    public static func solve(_ sightings: [PoleSighting], poleHeight H: Double, pixelSigma: Double = 1.5,
                             dropOutliers: Bool = true) -> PoleFix? {
        guard var fix = solveOnce(sightings, poleHeight: H, pixelSigma: pixelSigma) else { return nil }
        guard dropOutliers, sightings.count >= 3 else { return fix }
        let sorted = fix.residualDegrees.values.sorted()
        let median = sorted[sorted.count / 2]
        if let worst = fix.residualDegrees.max(by: { $0.value < $1.value }),
           worst.value > max(3 * median, 0.02) {
            let kept = sightings.filter { $0.id != worst.key }
            if var refit = solveOnce(kept, poleHeight: H, pixelSigma: pixelSigma) {
                refit.dropped = [worst.key]
                refit.residualDegrees[worst.key] = worst.value
                fix = refit
            }
        }
        return fix
    }

    static func solveOnce(_ sightings: [PoleSighting], poleHeight H: Double, pixelSigma: Double) -> PoleFix? {
        guard !sightings.isEmpty else { return nil }
        // Pass 1 unweighted to get ranges; pass 2 weights each ray by 1/(angular sigma × range)².
        var base: SIMD3<Double>?
        var covariance = matrix_identity_double3x3
        for pass in 0..<2 {
            var A = simd_double3x3()
            var b = SIMD3<Double>()
            for s in sightings {
                let sigmaAngle = pixelSigma / s.intrinsics.fy
                for (ray, offset) in [(s.baseRay, SIMD3<Double>()), (s.tipRay, H * up)] {
                    var w = 1.0
                    if pass == 1, let p = base {
                        let range = max(0.5, simd_length(p + offset - ray.origin))
                        w = 1 / pow(sigmaAngle * range, 2)
                    }
                    let M = projector(ray.direction) * w
                    A += M
                    b += M * (ray.origin - offset)
                }
            }
            guard abs(A.determinant) > 1e-12 else { return nil }
            let inv = A.inverse
            base = inv * b
            covariance = inv
        }
        guard let p = base else { return nil }
        var residuals: [UUID: Double] = [:]
        for s in sightings {
            let rb = s.baseRay, rt = s.tipRay
            let angB = atan2(rb.distance(to: p), max(0.5, simd_length(p - rb.origin)))
            let angT = atan2(rt.distance(to: p + H * up), max(0.5, simd_length(p + H * up - rt.origin)))
            residuals[s.id] = RangeMath.degrees((angB + angT) / 2)
        }
        return PoleFix(base: p, covariance: covariance, used: sightings.map(\.id), dropped: [], residualDegrees: residuals)
    }
}

/// What the player sees after ranging: distance, height difference and line from the lie.
public struct RangeReport: Sendable {
    /// Horizontal distance from the lie to the lid, metres.
    public var distance: Double
    /// 1-sigma uncertainty of that distance, metres.
    public var distanceSigma: Double
    /// Lid ground minus lie ground, metres (positive = uphill).
    public var heightDifference: Double
    /// Horizontal offset lie → lid in ARKit world (x, z).
    public var offset: SIMD2<Double>
    /// Widest horizontal spread between photo positions, metres.
    public var baseline: Double
    /// Each photo's single-photo size range, for the cross-check.
    public var sizeRanges: [UUID: Double]
    /// Largest disagreement between any single-photo range and the fused range, percent.
    public var maxDisagreementPercent: Double
    public var photoCount: Int
    public var droppedCount: Int

    public static let disagreementLimitPercent = 3.0

    public var confident: Bool { maxDisagreementPercent <= Self.disagreementLimitPercent }
}

extension PoleSolver {
    /// Report relative to the lie: the first photo's position, `cameraHeight` above the ground.
    public static func report(_ sightings: [PoleSighting], poleHeight H: Double, cameraHeight: Double,
                              pixelSigma: Double = 1.5) -> RangeReport? {
        guard let first = sightings.first, let fix = solve(sightings, poleHeight: H, pixelSigma: pixelSigma) else { return nil }
        let lieCam = first.pose.position
        let lieGround = lieCam - SIMD3(0, cameraHeight, 0)
        let off = SIMD2(fix.base.x - lieGround.x, fix.base.z - lieGround.z)
        let dist = simd_length(off)
        let dir = dist > 0 ? SIMD3(off.x / dist, 0, off.y / dist) : SIMD3<Double>(0, 0, -1)
        let sigma = sqrt(max(0, simd_dot(dir, fix.covariance * dir)))

        var sizes: [UUID: Double] = [:]
        var worst = 0.0
        for s in sightings where fix.used.contains(s.id) {
            guard let single = solveOnce([s], poleHeight: H, pixelSigma: pixelSigma) else { continue }
            let o = s.pose.position - SIMD3(0, cameraHeight, 0)
            let dSingle = simd_length(SIMD2(single.base.x - o.x, single.base.z - o.z))
            let dFused = simd_length(SIMD2(fix.base.x - o.x, fix.base.z - o.z))
            sizes[s.id] = dSingle
            if dFused > 0 { worst = max(worst, abs(dSingle - dFused) / dFused * 100) }
        }

        var baseline = 0.0
        let positions = sightings.map(\.pose.position)
        for i in positions.indices { for j in positions.indices where j > i {
            baseline = max(baseline, simd_length(SIMD2(positions[i].x - positions[j].x, positions[i].z - positions[j].z)))
        } }

        return RangeReport(distance: dist, distanceSigma: sigma, heightDifference: fix.base.y - lieGround.y,
                           offset: off, baseline: baseline, sizeRanges: sizes, maxDisagreementPercent: worst,
                           photoCount: fix.used.count, droppedCount: fix.dropped.count)
    }
}
