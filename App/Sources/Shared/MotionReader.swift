import CoreMotion
import Foundation

/// CoreMotion gravity for the reticle: keeps the plumb line plumb and reads the angle below level.
///
/// Not available in the Simulator; callers fall back to the capture source's own aim there.
final class MotionReader: ObservableObject {
    /// Gravity in device coordinates (x right, y toward the top, z out of the screen), in g.
    @Published private(set) var gravity: SIMD3<Double>?

    private let manager = CMMotionManager()

    var isAvailable: Bool { manager.isDeviceMotionAvailable }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let g = motion?.gravity else { return }
            self?.gravity = SIMD3(g.x, g.y, g.z)
        }
    }

    func stop() { manager.stopDeviceMotionUpdates() }

    /// Screen direction of "up" (SwiftUI coordinates, y down) for a plumb line, as a unit vector.
    /// Straight up when there's no gravity or the phone is lying flat.
    static func plumbUp(gravity g: SIMD3<Double>?) -> CGVector {
        guard let g else { return CGVector(dx: 0, dy: -1) }
        // Device up is −g; device +y is screen −y.
        let x = -g.x, y = g.y
        let n = (x * x + y * y).squareRoot()
        guard n > 0.2 else { return CGVector(dx: 0, dy: -1) }
        return CGVector(dx: x / n, dy: y / n)
    }

    /// Angle of the back camera's line of sight below level, degrees (+ looking down).
    static func angleBelowLevel(gravity g: SIMD3<Double>) -> Double {
        // The back camera looks along device −z; its downward component is −g.z.
        let n = (g.x * g.x + g.y * g.y + g.z * g.z).squareRoot()
        guard n > 0 else { return 0 }
        return asin(max(-1, min(1, -g.z / n))) * 180 / .pi
    }
}
