import XCTest
import SafetyKit
@testable import BallisticsKit

/// The Swift port must give the browser prototype's numbers. `prototype-reference.json` was made by
/// running the prototype's own physics and solver code in Node on an open lawn (no trees or water).
final class PrototypeParityTests: XCTestCase {
    struct Ref: Decodable {
        struct W: Decodable { var x: Double; var y: Double }
        struct Carry: Decodable { var v, el, b: Double; var wind: W; var x, y: Double }
        struct Arc: Decodable { var ok: Bool; var el, b, restX, restY: Double?; var why: String? }
        struct Solve: Decodable { var tx, ty, v: Double; var wind: W; var roll: Bool; var low, high: Arc }
        var carry: [Carry]
        var solve: [Solve]
    }

    func reference() throws -> Ref {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "prototype-reference", withExtension: "json"))
        return try JSONDecoder().decode(Ref.self, from: Data(contentsOf: url))
    }

    func testFlightMatchesThePrototype() throws {
        for c in try reference().carry {
            let f = Solver.carry(speed: c.v, elevation: c.el, bearing: c.b, wind: Wind(east: c.wind.x, north: c.wind.y), landHeight: 0)
            XCTAssertEqual(f.landing.x, c.x, accuracy: 1e-4, "v \(c.v) el \(c.el)")
            XCTAssertEqual(f.landing.y, c.y, accuracy: 1e-4, "v \(c.v) el \(c.el)")
        }
    }

    func testSolutionsMatchThePrototype() throws {
        for r in try reference().solve {
            let charge = Charge(name: "ref", velocity: r.v)
            let s = Solver.solveWithRoll(target: Ground(r.tx, r.ty), charge: charge, wind: Wind(east: r.wind.x, north: r.wind.y),
                                         allowForRoll: r.roll)
            for (arc, ref) in [(Arc.low, r.low), (Arc.high, r.high)] {
                let sol = try XCTUnwrap(s[arc])
                XCTAssertEqual(sol.ok, ref.ok, "\(arc) to (\(r.tx), \(r.ty))")
                guard ref.ok else { continue }
                XCTAssertEqual(sol.elevation, try XCTUnwrap(ref.el), accuracy: 1e-3, "\(arc) elevation to (\(r.tx), \(r.ty))")
                XCTAssertEqual(Solver.wrap180(sol.bearing - (try XCTUnwrap(ref.b))), 0, accuracy: 1e-3, "\(arc) bearing")
                XCTAssertEqual(sol.rest.x, try XCTUnwrap(ref.restX), accuracy: 1e-2, "\(arc) rest east")
                XCTAssertEqual(sol.rest.y, try XCTUnwrap(ref.restY), accuracy: 1e-2, "\(arc) rest north")
            }
        }
    }
}

final class SolverTests: XCTestCase {
    /// The search flies with a 0.01 s step and the reported flight with 0.005 s, as the prototype does,
    /// so landings sit within a few tens of centimetres; spotting corrections take up the rest.
    func testSolutionLandsOnTheTarget() {
        let target = Ground(8, 52)
        let s = Solver.solve(target: target, charge: Charge.uncalibrated[4], wind: Wind(speed: 2, fromBearing: 270))
        for arc in Arc.allCases {
            let sol = s[arc]!
            XCTAssertTrue(sol.ok, "\(arc)")
            XCTAssertLessThan(Solver.length(sol.landing - target), 0.3, "\(arc) lands within 30 cm")
        }
        XCTAssertLessThan(s[.low]!.elevation, s[.high]!.elevation)
    }

    /// Wind from the west pushes east, so the computer aims left (upwind).
    func testCrosswindAimsUpwind() {
        let s = Solver.solve(target: Ground(0, 50), charge: Charge.uncalibrated[4], wind: Wind(speed: 3, fromBearing: 270))
        XCTAssertLessThan(s[.low]!.aimOffset, 0)
        XCTAssertLessThan(s[.high]!.aimOffset, s[.low]!.aimOffset, "the lob hangs longer, so it needs more")
    }

    func testUphillNeedsMoreElevation() {
        let flat = Solver.solve(target: Ground(0, 40), charge: Charge.uncalibrated[3], wind: .calm)[.low]!
        let up = Solver.solve(target: Ground(0, 40), charge: Charge.uncalibrated[3], wind: .calm, landHeight: 2)[.low]!
        XCTAssertTrue(up.ok)
        XCTAssertGreaterThan(up.elevation, flat.elevation)
        XCTAssertLessThan(Solver.length(up.landing - Ground(0, 40)), 0.3)
    }

    /// A potato that tops out below an uphill target hits the slope short of it.
    func testFlightBelowAnUphillTargetStopsShort() {
        let f = Flight.fly(speed: 8, elevation: 5, bearing: 0, wind: .calm, landHeight: 3)
        XCTAssertLessThan(f.apex, 3)
        XCTAssertLessThan(f.landing.y, 2)
    }

    func testNeverSolvesPastTheLimit() {
        let s = Solver.solve(target: Ground(0, Safety.limits.maxSolutionRange + 1), charge: Charge.uncalibrated[5], wind: .calm)
        XCTAssertEqual(s[.low]?.failure, .beyondLimit)
        XCTAssertEqual(s[.high]?.failure, .beyondLimit)
    }

    func testWeakChargesSayTooLong() {
        XCTAssertEqual(Solver.solve(target: Ground(0, 60), charge: Charge.uncalibrated[0], wind: .calm)[.low]?.failure, .tooLong)
    }

    func testChargesAreCappedBySafetyKit() {
        XCTAssertEqual(Charge(name: "hot", velocity: 300).velocity, Safety.limits.maxMuzzleVelocity)
        XCTAssertTrue(Charge.uncalibrated.allSatisfy { $0.velocity <= Safety.limits.maxMuzzleVelocity })
    }

    func testRollOutStopsShortOnSoftGround() {
        let f = Flight.fly(speed: 26, elevation: 15, bearing: 0, wind: .calm)
        let lawn = RollOut.rest(after: f, on: .lawn), sand = RollOut.rest(after: f, on: .sand)
        XCTAssertGreaterThan(lawn.y, sand.y)
        XCTAssertGreaterThanOrEqual(sand.y, f.landing.y)
    }

    func testTableHasBothArcsForEveryCharge() {
        let t = Solver.table(target: Ground(0, 45), wind: .calm, allowForRoll: false)
        XCTAssertEqual(t.count, Charge.uncalibrated.count * 2)
    }

    func testWindFromBearing() {
        let w = Wind(speed: 4, fromBearing: 0) // from the north: blows south
        XCTAssertEqual(w.east, 0, accuracy: 1e-12)
        XCTAssertEqual(w.north, -4, accuracy: 1e-12)
    }
}

final class DispersionTests: XCTestCase {
    func testSeededRoundsRepeat() {
        let sol = Solver.solve(target: Ground(0, 50), charge: Charge.uncalibrated[4], wind: .calm)[.low]!
        var a = SeededGenerator(seed: 42), b = SeededGenerator(seed: 42)
        XCTAssertEqual(Dispersion.standard.fire(sol, wind: .calm, using: &a).rest,
                       Dispersion.standard.fire(sol, wind: .calm, using: &b).rest)
    }

    /// Scatter should look like the prototype's: a few metres at 50 m, centred near the aim.
    func testScatterIsAFewMetresAt50m() {
        let target = Ground(0, 50)
        let sol = Solver.solve(target: target, charge: Charge.uncalibrated[4], wind: .calm)[.high]!
        var rng = SeededGenerator(seed: 7)
        let landings = (0..<400).map { _ in Dispersion.standard.fire(sol, wind: .calm, using: &rng).flight.landing }
        let mean = landings.reduce(Ground.zero, +) / Double(landings.count)
        let spread = (landings.map { Solver.length($0 - mean) * Solver.length($0 - mean) }.reduce(0, +) / Double(landings.count)).squareRoot()
        XCTAssertLessThan(Solver.length(mean - target), 1.5)
        XCTAssertGreaterThan(spread, 0.5)
        XCTAssertLessThan(spread, 6)
    }
}
