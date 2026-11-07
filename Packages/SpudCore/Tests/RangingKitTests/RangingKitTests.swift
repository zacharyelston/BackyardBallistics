import XCTest
import simd
@testable import RangingKit

final class RangeMathTests: XCTestCase {
    let H = 2.438  // 8 ft pole
    let hc = 1.5

    func testSubtenseRoundTrip() {
        for d in [3.0, 10, 30, 60, 90, 150] {
            let theta = RangeMath.poleSubtense(distance: d, poleHeight: H, cameraHeight: hc)
            let back = try! XCTUnwrap(RangeMath.distance(subtense: theta, poleHeight: H, cameraHeight: hc))
            XCTAssertEqual(back, d, accuracy: d * 1e-9)
        }
    }

    func testShortPoleBelowEyeLevel() {
        // 4 ft pole, camera above its tip.
        let short = 1.219
        for d in [2.0, 20, 60] {
            let theta = RangeMath.poleSubtense(distance: d, poleHeight: short, cameraHeight: hc)
            XCTAssertEqual(RangeMath.distance(subtense: theta, poleHeight: short, cameraHeight: hc)!, d, accuracy: 1e-6)
        }
    }

    func testDistanceFromSyntheticPixels() {
        // Camera looking level, principal point in the middle; pole 30 m away.
        let k = Intrinsics(fx: 3000, fy: 3000, cx: 1920, cy: 1080, width: 3840, height: 2160)
        let d = 30.0
        let tipY = k.cy - k.fy * (H - hc) / d
        let baseY = k.cy + k.fy * hc / d
        let est = try! XCTUnwrap(RangeMath.distance(tip: (k.cx, tipY), base: (k.cx, baseY), intrinsics: k,
                                                    poleHeight: H, cameraHeight: hc))
        XCTAssertEqual(est, d, accuracy: 1e-6)
    }

    func testRayAtPrincipalPointIsForward() {
        let k = Intrinsics(fx: 1000, fy: 1000, cx: 500, cy: 400, width: 1000, height: 800)
        XCTAssertEqual(k.ray(x: 500, y: 400), SIMD3(0, 0, 1))
    }

    func testFOVIntrinsics() {
        let k = Intrinsics(horizontalFOVDegrees: 90, width: 2000, height: 1000)
        XCTAssertEqual(k.fx, 1000, accuracy: 1e-9)
    }

    func testOnePixelSensitivityGrowsWithDistance() {
        let near = RangeMath.sensitivity(distance: 10, poleHeight: H, cameraHeight: hc, focalPixels: 3000)
        let far = RangeMath.sensitivity(distance: 90, poleHeight: H, cameraHeight: hc, focalPixels: 3000)
        XCTAssertLessThan(near, far)
        // At 90 m on a ~3000 px lens the pole is ~81 px tall, so 1 px is ~1.2%.
        XCTAssertEqual(far / 90, 1.0 / 81, accuracy: 0.002)
    }

    func testOutOfRangeReturnsNil() {
        XCTAssertNil(RangeMath.distance(subtense: 0, poleHeight: H, cameraHeight: hc))
        XCTAssertNil(RangeMath.distance(subtense: 3.1, poleHeight: H, cameraHeight: hc))
    }
}

final class LeanMathTests: XCTestCase {
    func testUprightIsZero() {
        let r = try! XCTUnwrap(LeanMath.reading(gravity: SIMD3(0, -1, 0)))
        XCTAssertEqual(r.total, 0, accuracy: 1e-12)
    }

    func testUpsideDownIsRejected() {
        XCTAssertNil(LeanMath.reading(gravity: SIMD3(0, 1, 0)))
    }

    func testTwoFaceRemovesBias() {
        let lean = LeanReading(across: 0.3, through: -0.2)
        let bias = LeanReading(across: 0.4, through: 0.25)
        let a = LeanReading(across: lean.across + bias.across, through: lean.through + bias.through)
        let b = LeanReading(across: -lean.across + bias.across, through: -lean.through + bias.through)
        let (l, s) = LeanMath.twoFace(a, b)
        XCTAssertEqual(l.across, 0.3, accuracy: 1e-12)
        XCTAssertEqual(l.through, -0.2, accuracy: 1e-12)
        XCTAssertEqual(s.across, 0.4, accuracy: 1e-12)
    }

    func testReadingMatchesTilt() {
        let tilt = RangeMath.radians(2)
        let r = try! XCTUnwrap(LeanMath.reading(gravity: SIMD3(sin(tilt), -cos(tilt), 0)))
        XCTAssertEqual(r.across, 2, accuracy: 1e-9)
    }
}

final class PoleGeometryTests: XCTestCase {
    func testHeightFromTipRay() {
        let base = SIMD3(0.0, 0, -3)
        let eye = SIMD3(0.0, 1.5, 0)
        let tip = SIMD3(0.0, 2.438, -3)
        let h = try! XCTUnwrap(PoleGeometry.height(base: base, tipRayOrigin: eye, tipRayDirection: tip - eye))
        XCTAssertEqual(h, 2.438, accuracy: 1e-9)
    }

    func testOffAxisTapStillFindsClosestHeight() {
        // Tap lands 2 cm to the side of the tip; height should barely change.
        let base = SIMD3(1.0, -0.1, -2.5)
        let eye = SIMD3(0.0, 1.4, 0)
        let tipSide = SIMD3(1.02, 2.338, -2.5)
        let h = try! XCTUnwrap(PoleGeometry.height(base: base, tipRayOrigin: eye, tipRayDirection: tipSide - eye))
        XCTAssertEqual(h, 2.438, accuracy: 0.01)
    }
}

final class FieldCSVTests: XCTestCase {
    func testCSVHasHeaderAndRow() {
        let k = Intrinsics(fx: 3000, fy: 3000, cx: 1920, cy: 1080, width: 3840, height: 2160)
        let s = FieldSample(lens: "1×", approximateIntrinsics: false, trueDistance: 30, poleHeight: 2.438, cameraHeight: 1.5,
                            tip: (1920, 1080 - 3000 * 0.938 / 30), base: (1920, 1080 + 3000 * 1.5 / 30), intrinsics: k,
                            note: "test \"quoted\"")
        let csv = FieldCSV.make([s])
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].contains("30.000"))
        XCTAssertTrue(lines[1].hasSuffix("\"test \"\"quoted\"\"\""))
        XCTAssertEqual(s.error!, 0, accuracy: 1e-6)
    }
}
