import XCTest
import simd
import CoreGeo
@testable import RangingKit

final class ReticleRangeTests: XCTestCase {
    /// The spec's 4K wide camera (the prototype's CAM_F) and an 8 ft pole.
    let f = 3320.0
    let H = 8 * 0.3048

    func testSpecTable() {
        // Spec: 811/270/135/90 px at 10/30/60/90 m, 1σ about 2 cm, 16 cm, 63 cm, 1.4 m.
        let r = ReticleRange(focalPixels: f, poleHeight: H)
        let table: [(d: Double, px: Double, sigma: Double, sigmaTol: Double)] = [
            (10, 811, 0.02, 0.005), (30, 270, 0.16, 0.01), (60, 135, 0.63, 0.02), (90, 90, 1.4, 0.05)
        ]
        for row in table {
            // The spec rounds to whole pixels; 811 at 10 m is 809.5 exactly, so allow 2 px.
            XCTAssertEqual(r.linePixels(range: row.d), row.px, accuracy: 2, "pixels at \(row.d) m")
            XCTAssertEqual(r.range(linePixels: f * H / row.d)!, row.d, accuracy: 1e-9)
            XCTAssertEqual(r.sigma(range: row.d), row.sigma, accuracy: row.sigmaTol, "sigma at \(row.d) m")
        }
    }

    func testLevelIsThePlainStadiaFormula() {
        let r = ReticleRange(focalPixels: f, poleHeight: H)
        for h in [50.0, 120, 400, 900] {
            XCTAssertEqual(r.range(linePixels: h)!, f * H / h, accuracy: 1e-9)
        }
    }

    func testSigmaMatchesOnePixelEachEnd() {
        // ±1 px at each end in quadrature is √2 px on the line.
        let r = ReticleRange(focalPixels: f, poleHeight: H)
        for d in [10.0, 45, 90] {
            let h = r.linePixels(range: d)
            let shifted = r.range(linePixels: h - 2.0.squareRoot())!
            XCTAssertEqual(r.sigma(range: d), shifted - d, accuracy: (shifted - d) * 0.02)
        }
    }

    func testTiltCorrectionIsExactForAPitchedCamera() {
        // A portrait phone at eye height, looking straight at the base so the crosshair sits on it.
        let k = Intrinsics(fx: f, fy: f, cx: 1920, cy: 1080, width: 3840, height: 2160)
        for (d, drop) in [(10.0, 0.0), (10, 0.6), (25, -0.8), (60, 1.2)] {
            let eye = SIMD3<Double>(0, 1.5, 0)
            let base = SIMD3<Double>(0, -drop, -d)
            let pose = CameraPose.portrait(eye: eye, lookingAt: base)
            let pb = try! XCTUnwrap(pose.project(base, intrinsics: k))
            let pt = try! XCTUnwrap(pose.project(base + SIMD3(0, H, 0), intrinsics: k))
            XCTAssertEqual(pb.x, k.cx, accuracy: 1e-6)
            XCTAssertEqual(pb.y, k.cy, accuracy: 1e-6)
            let line = ((pt.x - pb.x) * (pt.x - pb.x) + (pt.y - pb.y) * (pt.y - pb.y)).squareRoot()

            let below = Geo.degrees(atan((1.5 + drop) / d))
            let r = ReticleRange(focalPixels: f, poleHeight: H, angleBelowLevel: below)
            XCTAssertEqual(r.range(linePixels: line)!, d, accuracy: 1e-6)
            XCTAssertEqual(r.linePixels(range: d), line, accuracy: 1e-6)
            XCTAssertEqual(ReticleRange.heightDifference(range: d, cameraHeight: 1.5, angleBelowLevel: below),
                           -drop, accuracy: 1e-9)
        }
    }

    func testTiltMattersOnlyCloseIn() {
        let flat = ReticleRange(focalPixels: f, poleHeight: H)
        let line10 = ReticleRange(focalPixels: f, poleHeight: H, angleBelowLevel: Geo.degrees(atan(1.5 / 10))).linePixels(range: 10)
        XCTAssertGreaterThan(flat.range(linePixels: line10)! - 10, -0.2)
        XCTAssertLessThan(flat.range(linePixels: line10)! - 10, -0.1) // ~14 cm short uncorrected at 10 m
        let line60 = ReticleRange(focalPixels: f, poleHeight: H, angleBelowLevel: Geo.degrees(atan(1.5 / 60))).linePixels(range: 60)
        XCTAssertEqual(flat.range(linePixels: line60)!, 60, accuracy: 0.05)
    }

    func testLockPlacesThePoleFromGPSBearingAndDistance() {
        let lie = GeoPoint(latitude: 42.36012, longitude: -71.05888)
        let lock = ReticleLock(reticle: ReticleRange(focalPixels: f, poleHeight: H, angleBelowLevel: 1.0),
                               range: 50, bearing: 30, cameraHeight: 1.5, location: lie, horizontalAccuracy: 4)
        XCTAssertEqual(Geo.distance(lie, lock.polePosition), 50, accuracy: 0.01)
        XCTAssertEqual(Geo.bearing(from: lie, to: lock.polePosition), 30, accuracy: 0.01)
        let en = lock.eastNorth
        XCTAssertEqual(Geo.distance(Geo.offset(lie, east: en.east, north: en.north), lock.polePosition), 0, accuracy: 0.001)
        XCTAssertEqual(lock.heightDifference, 1.5 - 50 * tan(Geo.radians(1)), accuracy: 1e-9)
        XCTAssertEqual(lock.sigma, ReticleRange(focalPixels: f, poleHeight: H).sigma(range: 50), accuracy: 1e-12)
    }
}

final class FireControlTests: XCTestCase {
    func testInitialStep() {
        XCTAssertEqual(FireControl.initialStep(range: 20), 2)
        XCTAssertEqual(FireControl.initialStep(range: 80), 4.8, accuracy: 1e-12)
    }

    func testBracketingHalvesOnlyOnceBracketed() {
        var fc = FireControl(lockedRange: 50) // step 3
        XCTAssertEqual(fc.record(Spot(call: .short, lateral: 0)).addDrop, 3, accuracy: 1e-12)
        XCTAssertFalse(fc.bracketed)
        XCTAssertEqual(fc.record(Spot(call: .short, lateral: 0)).addDrop, 3, accuracy: 1e-12)
        // Change of call: bracketed, halve before applying.
        XCTAssertEqual(fc.record(Spot(call: .over, lateral: 0)).addDrop, -1.5, accuracy: 1e-12)
        XCTAssertTrue(fc.bracketed)
        XCTAssertEqual(fc.record(Spot(call: .over, lateral: 0)).addDrop, -0.75, accuracy: 1e-12)
        XCTAssertEqual(fc.record(Spot(call: .short, lateral: 0)).addDrop, 0.5, accuracy: 1e-12) // floor
        XCTAssertEqual(fc.aimRange, 50 + 3 + 3 - 1.5 - 0.75 + 0.5, accuracy: 1e-12)
    }

    func testRangeCorrectBracketsWithoutMoving() {
        var fc = FireControl(lockedRange: 30) // step 2
        XCTAssertEqual(fc.record(Spot(call: .rangeCorrect, lateral: 0)).addDrop, 0)
        XCTAssertTrue(fc.bracketed)
        XCTAssertEqual(fc.step, 2)
        XCTAssertEqual(fc.record(Spot(call: .over, lateral: 0)).addDrop, -1, accuracy: 1e-12)
    }

    func testLateralCorrectsByMeanMeasuredMiss() {
        var fc = FireControl(lockedRange: 40)
        // A steady 2 m right drift with ±0.5 m scatter.
        var c = fc.record(Spot(call: .rangeCorrect, lateral: 2.5))
        XCTAssertEqual(c.rightLeft, -2.5, accuracy: 1e-12)
        // Fired 2.5 m left of the line, so a raw 1.5 m right miss lands 1.0 m left.
        c = fc.record(Spot(call: .rangeCorrect, lateral: -1.0))
        XCTAssertEqual(fc.lateralCorrection, -2.0, accuracy: 1e-12) // mean of 2.5 and 1.5
        XCTAssertEqual(c.rightLeft, 0.5, accuracy: 1e-12)
    }

    func testCrosshairAngleTimesRange() {
        XCTAssertEqual(Spotting.lateralMiss(crosshairAngleDegrees: 1, range: 60), 60 * tan(Geo.radians(1)), accuracy: 1e-12)
        XCTAssertEqual(Spot(call: .short, crosshairAngleDegrees: -2, range: 30).lateral, -30 * tan(Geo.radians(2)), accuracy: 1e-12)
    }
}

final class CameraAimTests: XCTestCase {
    func testAimOfAPitchedPortraitPose() {
        // Pole base 40 m north-east-ish and 1.5 m below the eye.
        let eye = SIMD3<Double>(0, 1.5, 0)
        let base = SIMD3<Double>(30, 0, -40) // 30 m east, 40 m north
        let aim = CameraPose.portrait(eye: eye, lookingAt: base).aim
        XCTAssertEqual(aim.bearing, Geo.degrees(atan2(30, 40)), accuracy: 1e-9)
        XCTAssertEqual(aim.angleBelowLevel, Geo.degrees(atan(1.5 / 50)), accuracy: 1e-9)
        XCTAssertEqual(CameraPose.portrait(eye: eye, facing: base).aim.angleBelowLevel, 0, accuracy: 1e-9)
    }
}
