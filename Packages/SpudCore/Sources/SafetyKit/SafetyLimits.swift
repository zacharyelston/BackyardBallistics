import Foundation

/// The one projectile the game knows about. There is no setting to change it.
public struct Projectile: Codable, Equatable, Sendable {
    public var name: String
    public var massKg: Double
    public var diameterM: Double
}

/// Every safety number in one place. Nothing else in the codebase may restate these values.
///
/// The same values ship as `safety-limits.json` (bundled with this module) so other clients,
/// such as the browser prototype, read identical numbers. Tests fail if the two disagree.
public struct SafetyLimits: Codable, Equatable, Sendable {
    public var version: Int
    /// Highest muzzle velocity any calibrated charge setting may have, m/s.
    public var maxMuzzleVelocity: Double
    /// Longest distance the firing computer will solve for, m (100 yd).
    public var maxSolutionRange: Double
    /// How far a ranged hole may land from a published flag point, m.
    public var flagGateTolerance: Double
    /// Radius of each firing point's safety fan, m (105 yd).
    public var fanRange: Double
    /// Half-angle of the safety fan either side of the line to the hole, degrees.
    public var fanHalfAngle: Double
    public var projectile: Projectile

    public static let current = SafetyLimits(
        version: 1,
        maxMuzzleVelocity: 45,
        maxSolutionRange: 91.44,
        flagGateTolerance: 10,
        fanRange: 96.012,
        fanHalfAngle: 30,
        projectile: Projectile(name: "Potato", massKg: 0.2, diameterM: 0.07)
    )

    /// The bundled JSON copy, for checking it matches `current`.
    public static func bundled() -> SafetyLimits? {
        guard let url = Bundle.module.url(forResource: "safety-limits", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(SafetyLimits.self, from: data)
    }
}
