import Foundation
import SafetyKit

/// Positions are local metres from the launcher's ground point: `x` east, `y` north, `z` up.
/// Bearings are degrees clockwise from north. The model matches the browser prototype exactly
/// (same constants and the same Euler step), so the app and the prototype give the same answers.
public typealias Ground = SIMD2<Double>

/// Wind the potato flies through, m/s toward east and north (the direction it blows *to*).
public struct Wind: Codable, Equatable, Sendable {
    public var east: Double
    public var north: Double
    public init(east: Double, north: Double) { self.east = east; self.north = north }
    public static let calm = Wind(east: 0, north: 0)

    /// From a speed and the compass direction the wind blows *from* (how players read a windsock).
    public init(speed: Double, fromBearing: Double) {
        let to = (fromBearing + 180) * .pi / 180
        self.init(east: speed * sin(to), north: speed * cos(to))
    }

    public var speed: Double { (east * east + north * north).squareRoot() }

    /// Wind is stronger with height, so lobs that hang high drift more. `z` in metres.
    public static func shear(_ z: Double) -> Double {
        min(1.7, max(0.6, pow(max(z, 0.3) / 2, 0.25)))
    }
}

/// The physics constants. The projectile is the one SafetyKit allows; nothing here can change it.
public enum Physics {
    public static let g = 9.81
    public static let dragCoefficient = 0.6
    public static let airDensity = 1.2
    /// Muzzle height above the launcher's ground, metres.
    public static let muzzleHeight = 1.0
    public static let maxElevation = 88.0

    /// Drag acceleration is `k·|v|²`.
    public static var k: Double {
        let p = Safety.limits.projectile
        let area = Double.pi * pow(p.diameterM / 2, 2)
        return 0.5 * airDensity * dragCoefficient * area / p.massKg
    }
}

public struct FlightResult: Equatable, Sendable {
    /// Where the potato comes down (east, north), metres from the launcher.
    public var landing: Ground
    public var time: Double
    public var apex: Double
    /// Velocity at landing, m/s (east, north, up).
    public var velocity: SIMD3<Double>
    /// Sampled path (east, north, up, time) when requested.
    public var path: [SIMD4<Double>]
}

public enum Flight {
    /// Flies one potato. Point-mass flight with quadratic drag relative to a height-sheared wind.
    ///
    /// - Parameters:
    ///   - landHeight: ground height where it comes down, relative to the launcher's ground (+ uphill).
    ///   - knuckle: small sideways push from a lumpy potato, m/s² (east, north); zero for the solver.
    public static func fly(speed v: Double, elevation: Double, bearing: Double, wind: Wind,
                           landHeight: Double = 0, knuckle: Ground = .zero, dt: Double = 0.005,
                           recordPath: Bool = false) -> FlightResult {
        let e = elevation * .pi / 180, b = bearing * .pi / 180, k = Physics.k
        var x = 0.0, y = 0.0, z = Physics.muzzleHeight, t = 0.0, apex = z
        var vx = v * cos(e) * sin(b), vy = v * cos(e) * cos(b), vz = v * sin(e)
        var path: [SIMD4<Double>] = recordPath ? [SIMD4(x, y, z, 0)] : []
        var lastRec = 0.0
        // Uphill past the muzzle, a potato can only land once it has risen above the target's height;
        // one that tops out below it hits the slope short of the target.
        var cleared = z > landHeight
        while t < 40 {
            if !cleared && vz < 0 { break }
            let f = Wind.shear(z), rx = vx - wind.east * f, ry = vy - wind.north * f
            let s = (rx * rx + ry * ry + vz * vz).squareRoot()
            vx += (-k * s * rx + knuckle.x) * dt
            vy += (-k * s * ry + knuckle.y) * dt
            vz += (-Physics.g - k * s * vz) * dt
            let nx = x + vx * dt, ny = y + vy * dt, nz = z + vz * dt
            if cleared && nz <= landHeight && vz < 0 {
                let f2 = (z - landHeight) / (z - nz)
                x += (nx - x) * f2; y += (ny - y) * f2; t += dt * f2; z = landHeight
                break
            }
            x = nx; y = ny; z = nz; t += dt
            if z > apex { apex = z }
            if z > landHeight { cleared = true }
            if recordPath && t - lastRec >= 0.02 { path.append(SIMD4(x, y, z, t)); lastRec = t }
        }
        if recordPath { path.append(SIMD4(x, y, z, t)) }
        return FlightResult(landing: Ground(x, y), time: t, apex: apex, velocity: SIMD3(vx, vy, vz), path: path)
    }
}

/// What the potato lands on. Sets how much speed survives the bounce and how fast it slows.
public enum Surface: String, Codable, CaseIterable, Sendable {
    case lawn, shortGrass, rough, sand

    public var label: String {
        switch self {
        case .lawn: return "Lawn"
        case .shortGrass: return "Short grass"
        case .rough: return "Rough"
        case .sand: return "Sand or soft ground"
        }
    }
    /// Fraction of horizontal speed kept after landing.
    var retention: Double { switch self { case .lawn: 0.35; case .shortGrass: 0.45; case .rough: 0.15; case .sand: 0.03 } }
    /// Rolling deceleration, m/s².
    var deceleration: Double { switch self { case .lawn: 3.5; case .shortGrass: 2.2; case .rough: 9; case .sand: 40 } }
}

public enum RollOut {
    /// Where a landed potato comes to rest on one surface (no hazards: the app has no ground map).
    public static func rest(after flight: FlightResult, on surface: Surface, headingNoise: Double = 0) -> Ground {
        var sp = (flight.velocity.x * flight.velocity.x + flight.velocity.y * flight.velocity.y).squareRoot() * surface.retention
        let dir = atan2(flight.velocity.x, flight.velocity.y) + headingNoise
        var p = flight.landing, t = 0.0
        let dt = 0.01
        while sp > 0.02 && t < 25 {
            sp = max(0, sp - surface.deceleration * dt)
            p += Ground(sin(dir), cos(dir)) * sp * dt
            t += dt
        }
        return p
    }
}
