import XCTest
import CoreGeo
@testable import SafetyKit

final class SafetyLimitsTests: XCTestCase {
    /// Loosening a limit must be a deliberate, reviewed change: update this test on purpose.
    func testLimitValuesArePinned() {
        let l = SafetyLimits.current
        XCTAssertEqual(l.version, 1)
        XCTAssertEqual(l.maxMuzzleVelocity, 45)
        XCTAssertEqual(l.maxSolutionRange, 91.44)    // 100 yd
        XCTAssertEqual(l.flagGateTolerance, 10)
        XCTAssertEqual(l.fanRange, 96.012)           // 105 yd
        XCTAssertEqual(l.fanHalfAngle, 30)
        XCTAssertEqual(l.projectile, Projectile(name: "Potato", massKg: 0.2, diameterM: 0.07))
    }

    func testBundledJSONMatchesSwift() {
        XCTAssertEqual(SafetyLimits.bundled(), SafetyLimits.current)
    }

    /// Both browser prototypes carry their own copy of the limits; they must not drift.
    func testPrototypeMatchesLimits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let l = SafetyLimits.current
        for file in ["prototype/spudgungolf.html", "prototype/spudgungolf-v2.html"] {
            let html = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(html.contains("const V_CAP = \(Int(l.maxMuzzleVelocity));"), "\(file): velocity cap drifted")
            XCTAssertTrue(html.contains("const MAX_RANGE_M = \(l.maxSolutionRange);"), "\(file): range ceiling drifted")
            XCTAssertTrue(html.contains("const MASS = \(l.projectile.massKg), DIA = \(l.projectile.diameterM)"), "\(file): projectile drifted")
        }
    }
}

final class SafetyChecksTests: XCTestCase {
    func testCalibrationCap() {
        XCTAssertTrue(Safety.checkCalibration(muzzleVelocity: 44.9).isAllowed)
        XCTAssertTrue(Safety.checkCalibration(muzzleVelocity: 45).isAllowed)
        XCTAssertEqual(Safety.checkCalibration(muzzleVelocity: 46).reasons, [.muzzleVelocityOverCap(measured: 46, cap: 45)])
    }

    func testSolutionNeedsRangeVelocityAndDownrange() {
        let ready = LauncherFixtures.conformingPneumatic(round: "r1")
        var log = DownrangeLog()
        func clear(_ d: Double, _ v: Double, _ launcher: LauncherConformance = ready) -> Result<Cleared<String>, SafetyBlock> {
            Safety.clearSolution("shot", distance: d, muzzleVelocity: v, launcher: launcher, roundID: "r1",
                                 downrange: log, player: "Zac", hole: 3)
        }
        // Not confirmed yet.
        guard case let .failure(b) = clear(60, 30) else { return XCTFail() }
        XCTAssertEqual(b.reasons, [.downrangeNotConfirmed])

        log.confirm(player: "Zac", hole: 3)
        guard case let .success(c) = clear(60, 30) else { return XCTFail() }
        XCTAssertEqual(c.value, "shot")
        XCTAssertEqual(c.limitsVersion, 1)

        // Confirmation is per player and per hole.
        XCTAssertFalse(log.isConfirmed(player: "Sam", hole: 3))
        XCTAssertFalse(log.isConfirmed(player: "Zac", hole: 4))

        guard case let .failure(b2) = clear(95, 50) else { return XCTFail() }
        XCTAssertEqual(b2.reasons.count, 2)
        XCTAssertTrue(b2.reasons.contains(.muzzleVelocityOverCap(measured: 50, cap: 45)))

        // A non-conforming launcher blocks even a perfect shot.
        var unready = ready
        unready.pressurePartsChanged()
        guard case let .failure(b3) = clear(60, 30, unready) else { return XCTFail() }
        XCTAssertTrue(b3.reasons.contains(where: { if case .launcherNotConforming = $0 { return true } else { return false } }))
    }

    func testFlagGate() {
        let lie = GeoPoint(latitude: 42.3601, longitude: -71.0589)
        let flag = Geo.offset(lie, east: 3, north: 64)
        let near = Safety.checkFlag(lie: lie, east: 0, north: 60, flag: flag)
        XCTAssertTrue(near.verdict.isAllowed)
        XCTAssertEqual(near.miss!, 5, accuracy: 0.01)
        XCTAssertFalse(Safety.checkFlag(lie: lie, east: 30, north: 30, flag: flag).verdict.isAllowed)
        XCTAssertEqual(Safety.checkFlag(lie: lie, east: 0, north: 60, flag: nil).verdict.reasons, [.noFlag])
        if case .success = Safety.clearRange(1, lie: lie, east: 30, north: 30, flag: flag) { XCTFail("far range cleared") }
    }

    func testSafetyFan() {
        let start = GeoPoint(latitude: 42.3601, longitude: -71.0589)
        let hole = Geo.offset(start, east: 0, north: 80)
        let big = GeoPolygon([Geo.offset(start, east: -150, north: -20), Geo.offset(start, east: 150, north: -20),
                              Geo.offset(start, east: 150, north: 150), Geo.offset(start, east: -150, north: 150)])
        XCTAssertTrue(Safety.checkFan(start: start, hole: hole, boundary: big).isAllowed)

        let narrow = GeoPolygon([Geo.offset(start, east: -20, north: -20), Geo.offset(start, east: 20, north: -20),
                                 Geo.offset(start, east: 20, north: 150), Geo.offset(start, east: -20, north: 150)])
        guard case let .blocked(r) = Safety.checkFan(start: start, hole: hole, boundary: narrow),
              case let .fanLeavesBoundary(n) = r.first else { return XCTFail() }
        XCTAssertGreaterThan(n, 0)

        XCTAssertEqual(Safety.checkFan(start: start, hole: hole, boundary: nil).reasons, [.noBoundary])
    }

    func testReasonsReadAsSentences() {
        for r: SafetyReason in [.noFlag, .downrangeNotConfirmed, .noBoundary,
                                .muzzleVelocityOverCap(measured: 50, cap: 45),
                                .beyondSolutionRange(distance: 95, limit: 91.44),
                                .flagTooFar(miss: 14, tolerance: 10), .fanLeavesBoundary(pointsOutside: 3),
                                .unsupportedLauncher, .launcherNotConforming(missing: [.reliefTest, .interlockTest]),
                                .inspectionNeeded, .inspectionFailed(items: [.bandsIntact]),
                                .pressureOverSetpoint(reading: 95, cap: 80)] {
            XCTAssertTrue(r.description.hasSuffix("."), r.description)
        }
    }
}
