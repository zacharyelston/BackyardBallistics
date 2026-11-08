import Foundation
import SafetyKit

/// One charge setting and the muzzle velocity it gives.
///
/// Until calibration shots exist (milestone 5) the app uses the prototype's table, which is a game
/// model, not a measurement of any real launcher. Every velocity is capped by SafetyKit.
public struct Charge: Codable, Equatable, Hashable, Identifiable, Sendable {
    public var name: String
    public var velocity: Double
    public var id: String { name }

    public init(name: String, velocity: Double) {
        self.name = name
        self.velocity = min(velocity, Safety.limits.maxMuzzleVelocity)
    }

    /// Uncalibrated defaults, from the browser prototype.
    public static let uncalibrated: [Charge] = [
        Charge(name: "Puff", velocity: 8), Charge(name: "1", velocity: 13), Charge(name: "2", velocity: 19),
        Charge(name: "3", velocity: 26), Charge(name: "4", velocity: 33), Charge(name: "5", velocity: 41)
    ]
}

public enum Arc: String, Codable, CaseIterable, Sendable {
    case low, high
    public var label: String { self == .low ? "Low" : "Lob" }
}

/// A firing solution for one charge and one arc.
public struct Solution: Equatable, Sendable {
    public enum Failure: String, Equatable, Sendable {
        /// Past the 100 yd limit: the computer never solves there.
        case beyondLimit
        /// This charge can't reach.
        case tooLong
        /// This charge overshoots even at its flattest (low) or steepest (lob) arc.
        case tooShort
    }

    public var charge: Charge
    public var arc: Arc
    public var failure: Failure?
    /// Elevation, degrees above level.
    public var elevation = 0.0
    /// Compass bearing to aim along, degrees.
    public var bearing = 0.0
    /// Aim left (−) or right (+) of the line to the target, degrees: the wind correction.
    public var aimOffset = 0.0
    public var timeOfFlight = 0.0
    /// Highest point above the launcher's ground, metres.
    public var apex = 0.0
    public var landing: Ground = .zero
    /// Where the roll-out model says it stops.
    public var rest: Ground = .zero
    /// Distance from the rest point to the target, metres.
    public var miss = 0.0

    public var ok: Bool { failure == nil }
}

public enum Solver {
    /// Range along a bearing at one elevation (the solver's coarse step).
    static func carry(speed v: Double, elevation: Double, bearing: Double, wind: Wind, landHeight: Double) -> FlightResult {
        Flight.fly(speed: v, elevation: elevation, bearing: bearing, wind: wind, landHeight: landHeight, dt: 0.01)
    }

    static func bearing(to p: Ground) -> Double { atan2(p.x, p.y) * 180 / .pi }
    static func wrap180(_ a: Double) -> Double { ((a.truncatingRemainder(dividingBy: 360)) + 540).truncatingRemainder(dividingBy: 360) - 180 }

    /// Low and lob solutions to land on `target` (east/north metres from the launcher).
    ///
    /// - Parameter landHeight: the target's ground height relative to the launcher's ground (+ uphill).
    public static func solve(target: Ground, charge: Charge, wind: Wind, landHeight: Double = 0) -> [Arc: Solution] {
        let v = charge.velocity
        let b0 = bearing(to: target)
        // Elevation for the longest carry (golden-section search), splitting the low and lob arcs.
        var lo = 0.0, hi = 80.0
        for _ in 0..<24 {
            let m1 = lo + (hi - lo) * 0.382, m2 = lo + (hi - lo) * 0.618
            let d1 = length(carry(speed: v, elevation: m1, bearing: b0, wind: wind, landHeight: landHeight).landing)
            let d2 = length(carry(speed: v, elevation: m2, bearing: b0, wind: wind, landHeight: landHeight).landing)
            if d1 < d2 { lo = m1 } else { hi = m2 }
        }
        let em = (lo + hi) / 2
        var out: [Arc: Solution] = [:]
        for arc in Arc.allCases {
            out[arc] = solveArc(target: target, charge: charge, wind: wind, arc: arc, maxCarryElevation: em, b0: b0, landHeight: landHeight)
        }
        return out
    }

    static func solveArc(target: Ground, charge: Charge, wind: Wind, arc: Arc, maxCarryElevation em: Double,
                         b0: Double, landHeight: Double) -> Solution {
        var sol = Solution(charge: charge, arc: arc)
        let v = charge.velocity, d = length(target)
        if d > Safety.limits.maxSolutionRange { sol.failure = .beyondLimit; return sol }
        func dist(_ el: Double, _ b: Double) -> Double { length(carry(speed: v, elevation: el, bearing: b, wind: wind, landHeight: landHeight).landing) }
        var b = b0, el = 0.0
        for _ in 0..<6 {
            if d > dist(em, b) { sol.failure = .tooLong; return sol }
            var a = arc == .low ? 0 : em, c = arc == .low ? em : Physics.maxElevation
            if arc == .low && d < dist(a, b) { sol.failure = .tooShort; return sol }
            if arc == .high && d < dist(c, b) { sol.failure = .tooShort; return sol }
            for _ in 0..<24 {
                let m = (a + c) / 2
                if (dist(m, b) < d) == (arc == .low) { a = m } else { c = m }
            }
            el = (a + c) / 2
            let land = carry(speed: v, elevation: el, bearing: b, wind: wind, landHeight: landHeight).landing
            if length(land - target) < 0.05 { break }
            b += wrap180(b0 - bearing(to: land))
        }
        let f = Flight.fly(speed: v, elevation: el, bearing: b, wind: wind, landHeight: landHeight)
        sol.elevation = el
        sol.bearing = (b + 360).truncatingRemainder(dividingBy: 360)
        sol.aimOffset = wrap180(b - b0)
        sol.timeOfFlight = f.time
        sol.apex = f.apex
        sol.landing = f.landing
        return sol
    }

    /// Like `solve`, but aims the low arc short or long so the predicted roll-out stops on the target.
    public static func solveWithRoll(target: Ground, charge: Charge, wind: Wind, landHeight: Double = 0,
                                     surface: Surface = .lawn, allowForRoll: Bool = true) -> [Arc: Solution] {
        var aim = target
        var sol = solve(target: aim, charge: charge, wind: wind, landHeight: landHeight)
        if allowForRoll {
            for _ in 0..<3 {
                guard let low = sol[.low], low.ok else { break }
                let rest = RollOut.rest(after: flight(low, wind: wind, landHeight: landHeight), on: surface)
                let e = target - rest
                if length(e) < 0.3 { break }
                aim += e
                let ns = solve(target: aim, charge: charge, wind: wind, landHeight: landHeight)
                guard let nl = ns[.low], nl.ok else { break } // roll-adjusted aim out of reach: keep the plain one
                sol[.low] = nl
            }
        }
        // Report every arc against the real target, with its rest point.
        let lineBearing = bearing(to: target)
        for arc in Arc.allCases {
            guard var s = sol[arc], s.ok else { continue }
            s.rest = RollOut.rest(after: flight(s, wind: wind, landHeight: landHeight), on: surface)
            s.miss = length(s.rest - target)
            s.aimOffset = wrap180(s.bearing - lineBearing)
            sol[arc] = s
        }
        return sol
    }

    /// Every charge's solutions, for the computer's table.
    public static func table(target: Ground, charges: [Charge] = Charge.uncalibrated, wind: Wind, landHeight: Double = 0,
                             surface: Surface = .lawn, allowForRoll: Bool = true) -> [Solution] {
        charges.flatMap { c -> [Solution] in
            let s = solveWithRoll(target: target, charge: c, wind: wind, landHeight: landHeight, surface: surface, allowForRoll: allowForRoll)
            return Arc.allCases.compactMap { s[$0] }
        }
    }

    static func flight(_ s: Solution, wind: Wind, landHeight: Double) -> FlightResult {
        Flight.fly(speed: s.charge.velocity, elevation: s.elevation, bearing: s.bearing, wind: wind, landHeight: landHeight)
    }

    static func length(_ p: Ground) -> Double { (p.x * p.x + p.y * p.y).squareRoot() }
}
