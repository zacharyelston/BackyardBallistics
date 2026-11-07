import Foundation
import simd

/// Pinhole camera intrinsics in the coordinates of the camera's native pixel buffer.
public struct Intrinsics: Codable, Equatable, Sendable {
    public var fx: Double
    public var fy: Double
    public var cx: Double
    public var cy: Double
    /// Size of the buffer these intrinsics refer to.
    public var width: Int
    public var height: Int

    public init(fx: Double, fy: Double, cx: Double, cy: Double, width: Int, height: Int) {
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.width = width; self.height = height
    }

    /// From AVFoundation's per-frame intrinsic matrix (column-major).
    public init(matrix m: simd_float3x3, width: Int, height: Int) {
        self.init(fx: Double(m.columns.0.x), fy: Double(m.columns.1.y),
                  cx: Double(m.columns.2.x), cy: Double(m.columns.2.y),
                  width: width, height: height)
    }

    /// Approximation from a horizontal field of view, centred principal point.
    public init(horizontalFOVDegrees fov: Double, width: Int, height: Int) {
        let f = Double(width) / 2 / tan(fov * .pi / 360)
        self.init(fx: f, fy: f, cx: Double(width) / 2, cy: Double(height) / 2, width: width, height: height)
    }

    /// Unit ray in camera coordinates (x right, y down, z forward) through a buffer pixel.
    public func ray(x: Double, y: Double) -> SIMD3<Double> {
        simd_normalize(SIMD3((x - cx) / fx, (y - cy) / fy, 1))
    }
}
