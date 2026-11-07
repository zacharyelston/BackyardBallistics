import Foundation

/// Pole lean read from the phone's gravity vector while the phone's back is held flat
/// against the pole, top of the phone pointing up.
public struct LeanReading: Codable, Equatable, Sendable {
    /// Degrees of lean toward the phone's right edge.
    public var across: Double
    /// Degrees of lean toward the phone's screen side.
    public var through: Double

    public init(across: Double, through: Double) {
        self.across = across
        self.through = through
    }

    /// Total lean in degrees.
    public var total: Double { (across * across + through * through).squareRoot() }
}

public enum LeanMath {
    /// Lean from a gravity vector in device coordinates (x right, y toward the top, z out of the screen).
    /// Returns nil when the phone's top is not pointing roughly up.
    public static func reading(gravity g: SIMD3<Double>) -> LeanReading? {
        let up = -g.y
        guard up > 0.5 else { return nil }
        return LeanReading(across: RangeMath.degrees(atan2(g.x, up)),
                           through: RangeMath.degrees(atan2(g.z, up)))
    }

    /// Two-face check: face B is the opposite side of the pole (phone turned 180° around it).
    /// The pole's lean flips sign between faces while the sensor's bias does not, so
    /// half the difference is the true lean and half the sum is the bias.
    public static func twoFace(_ a: LeanReading, _ b: LeanReading) -> (lean: LeanReading, bias: LeanReading) {
        (LeanReading(across: (a.across - b.across) / 2, through: (a.through - b.through) / 2),
         LeanReading(across: (a.across + b.across) / 2, through: (a.through + b.through) / 2))
    }

    /// The spec's setup limit.
    public static let limitDegrees = 0.5
}
