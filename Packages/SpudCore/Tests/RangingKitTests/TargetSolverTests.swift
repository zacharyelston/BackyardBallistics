import XCTest
import simd
import CoreGeo
@testable import RangingKit

final class TargetSolverTests: XCTestCase {
    let k = Intrinsics(fx: 2900, fy: 2900, cx: 2016, cy: 1512, width: 4032, height: 3024)
    let target = SIMD3<Double>(1.5, 0.6, -12)       // a stump 12 m north
    let stickBase = SIMD3<Double>(0.6, 0, -11)       // the stick stands next to it, 1 m tall
    let stick = ScaleStick.meterQuarters

    /// A shot from `eye`, looking between the target and the stick. `drift` scales where ARKit
    /// thinks the camera is (its scale error); `noise` jitters the marked pixels.
    private func shot(_ eye: SIMD3<Double>, drift: Double = 1, noise: Double = 0, seed: inout UInt64,
                      gps: GeoPoint? = nil) -> TargetSighting {
        func n() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return (Double(seed >> 11) / Double(1 << 53) - 0.5) * 2 * noise
        }
        let truePose = CameraPose.portrait(eye: eye, lookingAt: (target + stickBase) / 2)
        func px(_ p: SIMD3<Double>) -> Pixel {
            let q = truePose.project(p, intrinsics: k)!
            return Pixel(x: q.x + n(), y: q.y + n())
        }
        var marks: [Int: Pixel] = [:]
        marks[0] = px(stickBase)
        marks[4] = px(stickBase + SIMD3(0, 1, 0))
        // ARKit's view of the same shot: the camera position scaled about the origin, same aim.
        var reported = truePose
        let p = truePose.position * drift
        reported.columns[12] = p.x; reported.columns[13] = p.y; reported.columns[14] = p.z
        return TargetSighting(pose: reported, intrinsics: k, target: px(target), stickMarks: marks,
                              location: gps, horizontalAccuracy: 4)
    }

    func testTwoShotsTriangulateExactly() throws {
        var s: UInt64 = 1
        let shots = [shot(SIMD3(-2, 1.6, 0), seed: &s), shot(SIMD3(2.5, 1.6, 0.5), seed: &s)]
        let fix = try XCTUnwrap(TargetSolver.solve(shots, stick: stick))
        XCTAssertLessThan(simd_length(fix.position - target), 1e-6)
        XCTAssertEqual(fix.scale, 1, accuracy: 1e-6)
        XCTAssertEqual(fix.measuredStick ?? 0, 1, accuracy: 1e-6)
        XCTAssertTrue(fix.wellConditioned)
        XCTAssertEqual(fix.heightFromCameras, 0.6 - 1.6 + 0.0, accuracy: 0.05)
    }

    func testTheStickTakesOutARKitScaleError() throws {
        var s: UInt64 = 2
        // ARKit reads the walk 4% long.
        let eyes: [SIMD3<Double>] = [SIMD3(-3, 1.6, 0), SIMD3(3, 1.6, -1), SIMD3(0, 1.5, 2)]
        let shots = eyes.map { shot($0, drift: 1.04, seed: &s) }
        let fix = try XCTUnwrap(TargetSolver.solve(shots, stick: stick))
        XCTAssertEqual(fix.measuredStick ?? 0, 1.04, accuracy: 0.01, "the stick reads long by the drift")
        XCTAssertEqual(fix.scale, 1 / 1.04, accuracy: 0.005)
        // What matters is where the target is from the cameras (GPS anchors the cameras). Uncorrected
        // that would be ~4% of 12 m (~0.5 m) off; corrected, within a couple of cm.
        let trueCentre = eyes.reduce(.zero, +) / 3
        let reportedCentre = shots.map(\.pose.position).reduce(.zero, +) / 3
        let fromCameras = fix.position - reportedCentre
        XCTAssertLessThan(simd_length(fromCameras - (target - trueCentre)), 0.02)
    }

    func testPixelNoiseStaysUnderAMetre() throws {
        var s: UInt64 = 3
        let shots = [shot(SIMD3(-3, 1.6, 0), noise: 3, seed: &s), shot(SIMD3(3, 1.6, -1), noise: 3, seed: &s)]
        let fix = try XCTUnwrap(TargetSolver.solve(shots, stick: stick))
        XCTAssertLessThan(simd_length(fix.position - target), 0.3, "±3 px marking at 12 m")
        XCTAssertLessThan(fix.missRMS, 0.1)
    }

    func testShotsFromOneSpotAreFlagged() throws {
        var s: UInt64 = 4
        let shots = [shot(SIMD3(0, 1.6, 0), seed: &s), shot(SIMD3(0.3, 1.6, 0), seed: &s)]
        let fix = try XCTUnwrap(TargetSolver.solve(shots, stick: stick))
        XCTAssertFalse(fix.wellConditioned, "30 cm apart at 12 m is under 5°")
    }

    func testAMismarkedStickIsntApplied() throws {
        var s: UInt64 = 5
        var shots = [shot(SIMD3(-3, 1.6, 0), seed: &s), shot(SIMD3(3, 1.6, -1), seed: &s)]
        // Tapped the 0.5 m band but called it the top: it reads half length.
        for i in shots.indices {
            shots[i].stickMarks[4] = shots[i].pose.project(stickBase + SIMD3(0, 0.5, 0), intrinsics: k)
        }
        let fix = try XCTUnwrap(TargetSolver.solve(shots, stick: stick))
        XCTAssertEqual(fix.measuredStick ?? 0, 0.5, accuracy: 0.01)
        XCTAssertEqual(fix.scale, 1, "a 100% correction is a marking mistake, not drift")
    }

    func testTargetGPS() throws {
        var s: UInt64 = 6
        let o = GeoPoint(latitude: 42.36, longitude: -71.06)
        func gpsOf(_ eye: SIMD3<Double>) -> GeoPoint { Geo.offset(o, east: eye.x, north: -eye.z) }
        let e1 = SIMD3<Double>(-3, 1.6, 0), e2 = SIMD3<Double>(3, 1.6, -1)
        let shots = [shot(e1, seed: &s, gps: gpsOf(e1)), shot(e2, seed: &s, gps: gpsOf(e2))]
        let fix = try XCTUnwrap(TargetSolver.solve(shots, stick: stick))
        let truth = Geo.offset(o, east: target.x, north: -target.z)
        XCTAssertLessThan(Geo.distance(try XCTUnwrap(fix.location), truth), 0.05)
    }

    func testTriangulateNeedsTwoNonParallelRays() {
        XCTAssertNil(TargetSolver.triangulate([Ray3(origin: .zero, direction: SIMD3(0, 0, -1))]))
        XCTAssertNil(TargetSolver.triangulate([Ray3(origin: .zero, direction: SIMD3(0, 0, -1)),
                                               Ray3(origin: SIMD3(1, 0, 0), direction: SIMD3(0, 0, -1))]))
    }

    func testSightingsSurviveJSON() throws {
        var s: UInt64 = 7
        let a = shot(SIMD3(-2, 1.6, 0), seed: &s, gps: GeoPoint(latitude: 1, longitude: 2))
        let back = try JSONDecoder().decode(TargetSighting.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(back, a)
    }
}
