import Foundation
import simd

public enum PoleGeometry {
    /// Height of a pole whose base is at `base`, from a ray through its tip.
    ///
    /// Finds the point on the vertical line through the base that comes closest to the
    /// tip ray, and returns how far above the base it is. Assumes the pole is vertical,
    /// which the lean check confirms first.
    public static func height(base: SIMD3<Double>, tipRayOrigin o: SIMD3<Double>, tipRayDirection dir: SIMD3<Double>,
                              up: SIMD3<Double> = SIMD3(0, 1, 0)) -> Double? {
        let d = simd_normalize(dir)
        let u = simd_normalize(up)
        let w0 = base - o
        let b = simd_dot(u, d)
        let denom = 1 - b * b
        guard denom > 1e-6 else { return nil } // looking straight along the pole
        let s = (b * simd_dot(d, w0) - simd_dot(u, w0)) / denom
        return s
    }
}
