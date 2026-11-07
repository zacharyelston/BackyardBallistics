import XCTest
import simd
@testable import RangingKit
import CoreGeo

final class PoleSolverTests: XCTestCase {
    let H = 2.438
    let k = Intrinsics(fx: 3000, fy: 3000, cx: 1920, cy: 1080, width: 3840, height: 2160)

    /// Photos along a sideways arc at eye height 1.5 m, each aimed at the pole.
    func scene(base: SIMD3<Double>, photos: Int = 4, spread: Double = 3, noisePx: Double = 0,
               corrupt: (index: Int, basePx: Double)? = nil) -> [PoleSighting] {
        (0..<photos).map { i in
            let x = photos > 1 ? -spread / 2 + spread * Double(i) / Double(photos - 1) : 0
            let eye = SIMD3(x, 1.5, 0)
            let to = base - eye
            let yaw = RangeMath.degrees(atan2(-to.x, -to.z))
            let pose = CameraPose(position: eye, yawDegrees: yaw)
            var tip = pose.project(base + SIMD3(0, H, 0), intrinsics: k)!
            var b = pose.project(base, intrinsics: k)!
            if noisePx > 0 { // deterministic pseudo-noise in ±noisePx
                tip.x += noisePx * sin(Double(i) * 12.9898); tip.y += noisePx * sin(Double(i) * 78.233)
                b.x += noisePx * sin(Double(i) * 39.346); b.y += noisePx * sin(Double(i) * 11.135)
            }
            if let c = corrupt, c.index == i { b.y += c.basePx }
            return PoleSighting(pose: pose, intrinsics: k, tip: tip, base: b)
        }
    }

    func testRayConventions() {
        let pose = CameraPose(position: .zero)
        XCTAssertEqual(pose.ray(through: Pixel(x: k.cx, y: k.cy), intrinsics: k).direction, SIMD3(0, 0, -1))
        XCTAssertGreaterThan(pose.ray(through: Pixel(x: k.cx + 100, y: k.cy), intrinsics: k).direction.x, 0)
        XCTAssertLessThan(pose.ray(through: Pixel(x: k.cx, y: k.cy + 100), intrinsics: k).direction.y, 0)
    }

    func testProjectRoundTrip() {
        let pose = CameraPose(position: SIMD3(1, 1.5, 2), yawDegrees: 20)
        let p = SIMD3(-10.0, 0.3, -40)
        let px = pose.project(p, intrinsics: k)!
        let ray = pose.ray(through: px, intrinsics: k)
        XCTAssertLessThan(ray.distance(to: p), 1e-9)
    }

    func testExactMultiPhotoFix() {
        let truth = SIMD3(4.0, 0, -60)
        let fix = try! XCTUnwrap(PoleSolver.solve(scene(base: truth), poleHeight: H))
        XCTAssertLessThan(simd_length(fix.base - truth), 1e-6)
    }

    func testSinglePhotoMatchesSizeRange() {
        let truth = SIMD3(0.0, 0, -45)
        let one = scene(base: truth, photos: 1)
        let report = try! XCTUnwrap(PoleSolver.report(one, poleHeight: H, cameraHeight: 1.5))
        XCTAssertEqual(report.distance, 45, accuracy: 1e-6)
        let s = one[0]
        let sizeOnly = RangeMath.distance(subtense: RangeMath.subtendedAngle(s.tipRay.direction, s.baseRay.direction),
                                          poleHeight: H, cameraHeight: 1.5)!
        XCTAssertEqual(sizeOnly, 45, accuracy: 1e-6)
    }

    func testNoisyMarksStayWithinSigma() {
        let truth = SIMD3(2.0, 0, -60)
        let report = try! XCTUnwrap(PoleSolver.report(scene(base: truth, noisePx: 1), poleHeight: H, cameraHeight: 1.5))
        let trueDist = simd_length(SIMD2(truth.x + 1.5, truth.z)) // from the first photo at x = -1.5
        XCTAssertLessThan(abs(report.distance - trueDist), 3 * report.distanceSigma + 0.05)
        XCTAssertLessThan(report.distanceSigma, 1.0) // the spec's 60 m target on a 4K 1× frame is under a metre
        XCTAssertEqual(report.baseline, 3, accuracy: 1e-9)
    }

    func testOutlierPhotoIsDropped() {
        let truth = SIMD3(0.0, 0, -30)
        let photos = scene(base: truth, photos: 5, corrupt: (index: 2, basePx: 25))
        let fix = try! XCTUnwrap(PoleSolver.solve(photos, poleHeight: H))
        XCTAssertEqual(fix.dropped, [photos[2].id])
        XCTAssertLessThan(simd_length(fix.base - truth), 1e-6)
    }

    func testDisagreementFlagWithoutDropping() {
        let truth = SIMD3(0.0, 0, -30)
        let photos = scene(base: truth, photos: 2, corrupt: (index: 1, basePx: 25))
        let report = try! XCTUnwrap(PoleSolver.report(photos, poleHeight: H, cameraHeight: 1.5))
        XCTAssertFalse(report.confident)
    }

    /// The real-world case: a phone held in portrait, where the pole runs along the image's long
    /// (x) axis rather than up the buffer. The solver must not care how the phone was held.
    func testPortraitHeldPhonesGiveTheSameFix() {
        let k = Intrinsics(fx: 1450, fy: 1450, cx: 960, cy: 720, width: 1920, height: 1440)
        let truth = SIMD3(3.0, -0.3, -40)
        let photos = (0..<4).map { i -> PoleSighting in
            let pose = CameraPose.portrait(eye: SIMD3(Double(i), 1.5, 0), facing: truth)
            let tip = pose.project(truth + SIMD3(0, H, 0), intrinsics: k)!
            let base = pose.project(truth, intrinsics: k)!
            // In portrait the pole is near-vertical on screen, which is along buffer x.
            XCTAssertGreaterThan(abs(base.x - tip.x), 10 * abs(base.y - tip.y))
            XCTAssertGreaterThan(base.x, tip.x) // the base is lower on screen: larger buffer x
            return PoleSighting(pose: pose, intrinsics: k, tip: tip, base: base)
        }
        let fix = try! XCTUnwrap(PoleSolver.solve(photos, poleHeight: H))
        XCTAssertLessThan(simd_length(fix.base - truth), 1e-6)
    }

    func testHeightDifferenceDownhill() {
        let truth = SIMD3(0.0, -0.8, -25)
        let report = try! XCTUnwrap(PoleSolver.report(scene(base: truth), poleHeight: H, cameraHeight: 1.5))
        XCTAssertEqual(report.heightDifference, -0.8, accuracy: 1e-6)
        // Measured from the first photo (the lie), which sits 1.5 m left of the arc's centre.
        XCTAssertEqual(report.distance, (1.5 * 1.5 + 25 * 25).squareRoot(), accuracy: 1e-6)
    }
}

final class RangeReportGeoTests: XCTestCase {
    func testEastNorthFromAROffset() {
        let r = RangeReport(distance: 60, distanceSigma: 0.5, heightDifference: 0, offset: SIMD2(3, -60),
                            baseline: 3, sizeRanges: [:], maxDisagreementPercent: 0, photoCount: 3, droppedCount: 0)
        XCTAssertEqual(r.eastNorth.east, 3)
        XCTAssertEqual(r.eastNorth.north, 60)
    }
}
