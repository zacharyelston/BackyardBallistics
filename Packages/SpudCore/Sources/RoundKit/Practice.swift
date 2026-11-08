import Foundation
import CoreGeo
import RangingKit
import BallisticsKit

/// Practice mode: the whole fire mission with simulated rounds, on a loaded course's geometry.
/// Nothing is fired, so no launcher is involved; the numbers come from the game model.
///
/// Works in a local frame: metres east and north of the hole's firing point.
public struct PracticeRange: Sendable {
    /// Focal length of a full-resolution still, sensor pixels, for the simulated ranging error.
    public static let stillFocalPixels = 3000.0
    /// Doubtful band for a long/short call: a round this close along the line is called range correct.
    public static func doubtfulBand(range d: Double) -> Double { max(0.5, 0.02 * d) }

    public var pole: Ground
    public var poleHeight: Double
    /// The real wind for this hole. The player's estimate goes into the solver.
    public var wind: Wind
    public var surface: Surface
    public var dispersion: Dispersion
    private var rng: SeededGenerator

    public init(pole: Ground, poleHeight: Double, wind: Wind, surface: Surface = .lawn,
                dispersion: Dispersion = .standard, seed: UInt64) {
        self.pole = pole
        self.poleHeight = poleHeight
        self.wind = wind
        self.surface = surface
        self.dispersion = dispersion
        self.rng = SeededGenerator(seed: seed)
    }

    /// A random practice wind: up to `maxSpeed` m/s from any direction.
    public static func randomWind(seed: UInt64, maxSpeed: Double = 2.5) -> Wind {
        var g = SeededGenerator(seed: seed ^ 0xA5A5_5A5A)
        return Wind(speed: Double.random(in: 0...maxSpeed, using: &g), fromBearing: Double.random(in: 0..<360, using: &g))
    }

    /// A simulated reticle lock from `from`: the true range plus a draw from the still's ± (1σ).
    public mutating func lock(from: Ground) -> (range: Double, bearing: Double, sigma: Double) {
        let d = Self.length(pole - from)
        let sigma = ReticleRange(focalPixels: Self.stillFocalPixels, poleHeight: poleHeight).sigma(range: d)
        let bearing = atan2(pole.x - from.x, pole.y - from.y) * 180 / .pi
        return ((d + gauss() * sigma), (bearing + 360).truncatingRemainder(dividingBy: 360), sigma)
    }

    /// Fires one simulated round along a solution solved from `from`. Returns where it stopped
    /// (local frame) and its flight, for drawing.
    public mutating func fire(_ solution: Solution, from: Ground) -> (rest: Ground, landing: Ground, flight: FlightResult) {
        // The solution is relative to `from`; Dispersion works relative to the launcher.
        let shot = dispersion.fire(solution, wind: wind, surface: surface, using: &rng)
        return (from + shot.rest, from + shot.flight.landing, shot.flight)
    }

    /// What a spotter at `from` sees: a long/short call (with the doubtful band and some misjudging)
    /// and the left/right miss as the crosshair would measure it.
    public mutating func spot(rest: Ground, from: Ground) -> Spot {
        let line = pole - from
        let d = Self.length(line)
        let u = line / d, n = Ground(u.y, -u.x)
        let miss = rest - pole
        let along = (miss * u).sum()
        let lateral = (miss * n).sum() + gauss() * max(0.05, d * 0.0017)
        let band = Self.doubtfulBand(range: d)
        let judged = along + gauss() * 0.25 * band
        let call: RangeCall = abs(judged) <= band ? .rangeCorrect : judged < 0 ? .short : .over
        return Spot(call: call, lateral: lateral)
    }

    /// Distance from a rest point to the pole: walking out to verify.
    public func distanceToPole(_ p: Ground) -> Double { Self.length(p - pole) }

    private mutating func gauss() -> Double {
        var u = 0.0, v = 0.0
        while u == 0 { u = Double.random(in: 0..<1, using: &rng) }
        while v == 0 { v = Double.random(in: 0..<1, using: &rng) }
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    static func length(_ p: Ground) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }
}

public extension Mission {
    /// Fire control's aim point in a practice frame, given the mission's firing position there.
    func aimPoint(from origin: Ground) -> Ground {
        let a = aimPoint
        return origin + Ground(a.east, a.north)
    }
}

/// The firing computer's pick for a mission: the gentlest charge that reaches on the low arc,
/// else the gentlest lob.
public enum InitialData {
    public static func recommended(_ table: [Solution]) -> Solution? {
        table.first { $0.ok && $0.arc == .low } ?? table.first { $0.ok }
    }
}
