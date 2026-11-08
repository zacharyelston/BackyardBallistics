import Foundation

/// Round-to-round scatter: a lumpy potato, a gusty wind and an imperfect lay. The same model as the
/// browser prototype, used by practice mode to decide where a simulated round lands.
public struct Dispersion: Codable, Equatable, Sendable {
    /// One-sigma muzzle velocity spread, as a fraction.
    public var velocityFraction = 0.025
    /// One-sigma laying error in elevation and bearing, degrees.
    public var elevation = 0.5
    public var bearing = 0.8
    /// One-sigma gust strength (fraction of the mean wind) and gust direction swing, degrees.
    public var gust = 0.2
    public var gustRotation = 10.0
    /// One-sigma sideways push from a lumpy potato, m/s².
    public var knuckle = 0.15
    /// One-sigma change of direction on the first bounce, radians.
    public var bounce = 0.12

    public init() {}
    public static let standard = Dispersion()

    /// Fires one simulated round along `solution` and returns where it lands and where it stops.
    public func fire<R: RandomNumberGenerator>(_ solution: Solution, wind: Wind, landHeight: Double = 0,
                                               surface: Surface = .lawn, using rng: inout R) -> (flight: FlightResult, rest: Ground) {
        let v = solution.charge.velocity * (1 + Self.gauss(&rng) * velocityFraction)
        let el = min(Physics.maxElevation, max(0, solution.elevation + Self.gauss(&rng) * elevation))
        let br = solution.bearing + Self.gauss(&rng) * bearing
        let strength = 1 + Self.gauss(&rng) * gust, rot = Self.gauss(&rng) * gustRotation * .pi / 180
        let w = Wind(east: (wind.east * cos(rot) - wind.north * sin(rot)) * strength,
                     north: (wind.east * sin(rot) + wind.north * cos(rot)) * strength)
        let kn = Ground(Self.gauss(&rng) * knuckle, Self.gauss(&rng) * knuckle)
        let f = Flight.fly(speed: v, elevation: el, bearing: br, wind: w, landHeight: landHeight, knuckle: kn, recordPath: true)
        return (f, RollOut.rest(after: f, on: surface, headingNoise: Self.gauss(&rng) * bounce))
    }

    static func gauss<R: RandomNumberGenerator>(_ rng: inout R) -> Double {
        var u = 0.0, v = 0.0
        while u == 0 { u = Double.random(in: 0..<1, using: &rng) }
        while v == 0 { v = Double.random(in: 0..<1, using: &rng) }
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// A small seedable generator, so a practice round can be replayed and tests are repeatable.
public struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 { // SplitMix64
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
