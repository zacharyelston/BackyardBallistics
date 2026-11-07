import Foundation
import simd

/// Size ranging from a vertical pole of known height.
///
/// Uses the angle the pole subtends between its tip and base. This is independent of
/// how the phone is held, so it needs no gravity or orientation data. It assumes the
/// pole's base is level with the ground under the shooter; slope correction comes later.
public enum RangeMath {
    public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }
    public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    /// Angle between two rays, in radians.
    public static func subtendedAngle(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b)))))
    }

    /// Angle a pole of height `poleHeight` subtends from a camera `cameraHeight` above
    /// the ground, at horizontal distance `distance`. All in metres; result in radians.
    public static func poleSubtense(distance d: Double, poleHeight H: Double, cameraHeight hc: Double) -> Double {
        atan((H - hc) / d) + atan(hc / d)
    }

    /// Closest distance at which the subtense is still decreasing with distance.
    static func minimumDistance(poleHeight H: Double, cameraHeight hc: Double) -> Double {
        hc > H ? max(0.05, sqrt(hc * (hc - H)) * 1.01) : 0.05
    }

    /// Horizontal distance to the pole from its subtended angle (radians), or nil if out of range.
    public static func distance(subtense theta: Double, poleHeight H: Double, cameraHeight hc: Double) -> Double? {
        guard theta > 0, H > 0, hc >= 0 else { return nil }
        var lo = minimumDistance(poleHeight: H, cameraHeight: hc)
        var hi = 2000.0
        guard poleSubtense(distance: lo, poleHeight: H, cameraHeight: hc) >= theta,
              poleSubtense(distance: hi, poleHeight: H, cameraHeight: hc) <= theta else { return nil }
        for _ in 0..<100 {
            let mid = (lo + hi) / 2
            if poleSubtense(distance: mid, poleHeight: H, cameraHeight: hc) > theta { lo = mid } else { hi = mid }
        }
        return (lo + hi) / 2
    }

    /// Distance from two marked pixels (tip and base) in buffer coordinates.
    public static func distance(tip: (x: Double, y: Double), base: (x: Double, y: Double),
                                intrinsics k: Intrinsics, poleHeight H: Double, cameraHeight hc: Double) -> Double? {
        let theta = subtendedAngle(k.ray(x: tip.x, y: tip.y), k.ray(x: base.x, y: base.y))
        return distance(subtense: theta, poleHeight: H, cameraHeight: hc)
    }

    /// How far the range moves if the pole's length in the photo is off by `pixels`.
    public static func sensitivity(distance d: Double, poleHeight H: Double, cameraHeight hc: Double,
                                   focalPixels f: Double, pixels: Double = 1) -> Double {
        let theta = poleSubtense(distance: d, poleHeight: H, cameraHeight: hc)
        let dTheta = pixels / f
        guard let nearer = distance(subtense: theta + dTheta, poleHeight: H, cameraHeight: hc) else { return .nan }
        return abs(d - nearer)
    }
}
