import XCTest
@testable import SafetyKit

enum LauncherFixtures {
    static func passedInspection(_ kind: LauncherKind, round: String) -> Inspection {
        Inspection(roundID: round, results: Dictionary(uniqueKeysWithValues: InspectionItem.items(for: kind).map { ($0, true) }))
    }

    static func conformingPneumatic(round: String) -> LauncherConformance {
        var c = LauncherConformance(launcherID: "L1", name: "Shop standard", kind: .pneumaticStandard)
        c.ratingsDocumented = true
        c.reliefVented = true
        c.interlock.keyOffBlocked = true
        c.interlock.overPressureBlocked = true
        c.interlock.inhibitRelayBlocked = true
        c.calibratedMaxVelocity = 41
        c.maxSetpointPSI = 80
        c.inspection = passedInspection(.pneumaticStandard, round: round)
        return c
    }

    static func conformingElastic(round: String) -> LauncherConformance {
        var c = LauncherConformance(launcherID: "E1", name: "Three-person sling", kind: .elastic)
        c.calibratedMaxVelocity = 32
        c.inspection = passedInspection(.elastic, round: round)
        return c
    }
}

final class LauncherConformanceTests: XCTestCase {
    func testConformingLaunchersPass() {
        XCTAssertTrue(Safety.checkLauncher(LauncherFixtures.conformingPneumatic(round: "r1"), roundID: "r1").isAllowed)
        XCTAssertTrue(Safety.checkLauncher(LauncherFixtures.conformingElastic(round: "r1"), roundID: "r1").isAllowed)
    }

    func testOtherLaunchersNeverConform() {
        var c = LauncherFixtures.conformingPneumatic(round: "r1")
        c.kind = .other
        XCTAssertEqual(Safety.checkLauncher(c, roundID: "r1").reasons, [.unsupportedLauncher])
    }

    func testNewPneumaticListsEveryMissingStep() {
        let c = LauncherConformance(launcherID: "L2", name: "New", kind: .pneumaticStandard)
        let reasons = Safety.checkLauncher(c, roundID: "r1").reasons
        XCTAssertEqual(reasons.first, .launcherNotConforming(missing: [.ratingsDocumented, .reliefTest, .interlockTest, .velocityCap]))
        XCTAssertTrue(reasons.contains(.inspectionNeeded))
    }

    func testElasticSkipsPressureSteps() {
        XCTAssertEqual(ConformanceStep.required(for: .elastic), [.velocityCap, .preRoundInspection])
        let c = LauncherConformance(launcherID: "E2", name: "New sling", kind: .elastic)
        XCTAssertEqual(Safety.checkLauncher(c, roundID: "r1").reasons.first, .launcherNotConforming(missing: [.velocityCap]))
    }

    func testInterlockNeedsAllThreeCases() {
        var c = LauncherFixtures.conformingPneumatic(round: "r1")
        c.interlock.inhibitRelayBlocked = false
        XCTAssertEqual(Safety.checkLauncher(c, roundID: "r1").reasons, [.launcherNotConforming(missing: [.interlockTest])])
    }

    func testOverCapCalibrationBlocks() {
        var c = LauncherFixtures.conformingElastic(round: "r1")
        c.calibratedMaxVelocity = 47
        XCTAssertEqual(Safety.checkLauncher(c, roundID: "r1").reasons, [.muzzleVelocityOverCap(measured: 47, cap: 45)])
    }

    func testInspectionIsPerRoundAndEveryItemCounts() {
        let c = LauncherFixtures.conformingPneumatic(round: "r1")
        XCTAssertEqual(Safety.checkLauncher(c, roundID: "r2").reasons, [.inspectionNeeded])

        var failed = c
        failed.inspection?.results[.fittingsTight] = false
        failed.inspection?.results[.tankInTestDate] = nil
        XCTAssertEqual(Safety.checkLauncher(failed, roundID: "r1").reasons,
                       [.inspectionFailed(items: [.fittingsTight, .tankInTestDate])])
    }

    func testChangingPressurePartsVoidsEverything() {
        var c = LauncherFixtures.conformingPneumatic(round: "r1")
        c.pressurePartsChanged()
        XCTAssertEqual(c, LauncherConformance(launcherID: "L1", name: "Shop standard", kind: .pneumaticStandard))
        XCTAssertFalse(Safety.checkLauncher(c, roundID: "r1").isAllowed)
    }

    func testPressureInhibit() {
        let c = LauncherFixtures.conformingPneumatic(round: "r1")
        XCTAssertTrue(Safety.pressureInhibit(readingPSI: 80, launcher: c).isAllowed)
        XCTAssertEqual(Safety.pressureInhibit(readingPSI: 81, launcher: c).reasons, [.pressureOverSetpoint(reading: 81, cap: 80)])

        var noSetpoint = c
        noSetpoint.maxSetpointPSI = nil
        XCTAssertFalse(Safety.pressureInhibit(readingPSI: 10, launcher: noSetpoint).isAllowed)
        XCTAssertEqual(Safety.pressureInhibit(readingPSI: 10, launcher: LauncherFixtures.conformingElastic(round: "r1")).reasons,
                       [.unsupportedLauncher])
    }

    func testEveryStepAndItemHasWords() {
        for s in ConformanceStep.allCases { XCTAssertFalse(s.title.isEmpty); XCTAssertTrue(s.detail.hasSuffix(".")) }
        for i in InspectionItem.allCases { XCTAssertFalse(i.prompt.isEmpty) }
        XCTAssertTrue(InspectionItem.items(for: .other).isEmpty)
    }
}
