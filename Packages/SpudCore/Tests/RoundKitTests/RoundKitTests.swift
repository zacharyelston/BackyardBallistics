import XCTest
import CoreGeo
import RangingKit
import BallisticsKit
import CourseKit
@testable import RoundKit

final class RoundKitTests: XCTestCase {
    private let origin = GeoPoint(latitude: 42.36, longitude: -71.058)

    // MARK: Scoring

    func testScoreIsRoundsPlusMetresOutsideTheRing() {
        XCTAssertEqual(HoleRules.score(rounds: 3, closest: 2.43, inRadius: 1), 4.4)
        XCTAssertEqual(HoleRules.score(rounds: 2, closest: 0.6, inRadius: 1), 2)
        XCTAssertEqual(HoleRules.score(rounds: 4, closest: 1.5, inRadius: 1.5), 4)
    }

    // MARK: A hole

    private func hole(downrange: Bool, inRadius: Double = 1) -> HolePlay {
        HolePlay(holeNumber: 1, par: 4, inRadius: inRadius, downrangePlay: downrange)
    }

    func testBracketHitAndFinish() throws {
        var h = hole(downrange: false)
        XCTAssertEqual(h.phase, .setup)
        XCTAssertThrowsError(try h.record(Spot(call: .short, lateral: 0)))
        try h.begin(lockedRange: 30, bearing: 0, from: origin)
        let c1 = try h.record(Spot(call: .short, lateral: 1.2))
        XCTAssertEqual(c1.addDrop, 2, accuracy: 1e-9)          // max(2, 6% of 30)
        XCTAssertEqual(c1.rightLeft, -1.2, accuracy: 1e-9)
        let c2 = try h.record(Spot(call: .over, lateral: -0.4))
        XCTAssertEqual(c2.addDrop, -1, accuracy: 1e-9)         // bracketed: halve, then drop
        XCTAssertTrue(h.mission!.fireControl.bracketed)
        try h.record(Spot(call: .rangeCorrect, lateral: 0.1))
        let v = try h.ceaseFire(closest: 0.7)
        XCTAssertTrue(v.inRing)
        XCTAssertFalse(v.canResume)                             // a hit ends the hole
        XCTAssertFalse(v.canAdvance)
        XCTAssertEqual(try h.finish(), 3)
        XCTAssertEqual(h.phase, .finished)
        XCTAssertThrowsError(try h.finish())
    }

    func testResumeKeepsTheMissionAndRounds() throws {
        var h = hole(downrange: false)
        try h.begin(lockedRange: 40, bearing: 90, from: origin)
        try h.record(Spot(call: .short, lateral: 0))
        let v = try h.ceaseFire(closest: 4)
        XCTAssertFalse(v.canAdvance)                            // not a downrange hole
        XCTAssertTrue(v.canResume)
        XCTAssertEqual(v.score, 4)                               // 1 + 3 m outside
        XCTAssertThrowsError(try h.advance(lockedRange: 4, bearing: 0, from: nil))
        try h.resume()
        XCTAssertEqual(h.phase, .firing)
        XCTAssertNil(h.verdict)
        try h.record(Spot(call: .over, lateral: 0))
        XCTAssertEqual(h.roundsFired, 2)
        XCTAssertEqual(h.missions.count, 1)
    }

    func testDownrangeAdvanceStartsANewMissionAndKeepsCounting() throws {
        var h = hole(downrange: true)
        try h.begin(lockedRange: 80, bearing: 0, from: origin)
        try h.record(Spot(call: .short, lateral: 0))
        try h.record(Spot(call: .short, lateral: 0))
        let v = try h.ceaseFire(closest: 9)
        XCTAssertTrue(v.canAdvance)
        XCTAssertTrue(v.preferAdvance)                           // 8 m outside the ring
        try h.advance(lockedRange: 9, bearing: 10, from: nil)
        XCTAssertEqual(h.mission?.number, 2)
        XCTAssertEqual(h.mission?.fireControl.step, 2)           // fresh bracketing from the new lock
        try h.record(Spot(call: .rangeCorrect, lateral: 0.2))
        XCTAssertEqual(h.missionRounds.count, 1)
        let v2 = try h.ceaseFire(closest: 0.5)
        XCTAssertEqual(v2.score, 3)                              // every round on the hole counts
    }

    func testNoAdvanceWhenNothingWasFound() throws {
        var h = hole(downrange: true)
        try h.begin(lockedRange: 50, bearing: 0, from: origin)
        try h.recordLost()
        let v = try h.ceaseFire(closest: nil)
        XCTAssertFalse(v.canAdvance)
        XCTAssertEqual(v.closest, 50)                            // scored from where it was fired
        XCTAssertEqual(v.score, 50)
    }

    func testLostRoundCountsButLeavesFireControlAlone() throws {
        var h = hole(downrange: false)
        try h.begin(lockedRange: 30, bearing: 0, from: origin)
        let before = h.mission!.fireControl
        try h.recordLost()
        XCTAssertEqual(h.roundsFired, 1)
        XCTAssertTrue(h.rounds[0].lost)
        XCTAssertEqual(h.mission!.fireControl, before)
    }

    func testTenthRoundForcesCeaseFire() throws {
        var h = hole(downrange: true)
        try h.begin(lockedRange: 30, bearing: 0, from: origin)
        for _ in 0..<HoleRules.maxRoundsPerHole { try h.record(Spot(call: .short, lateral: 0)) }
        XCTAssertTrue(h.atRoundLimit)
        XCTAssertThrowsError(try h.record(Spot(call: .short, lateral: 0))) { XCTAssertEqual($0 as? HolePlayError, .roundLimit) }
        let v = try h.ceaseFire(closest: 5)
        XCTAssertFalse(v.canResume)
        XCTAssertFalse(v.canAdvance)
        XCTAssertEqual(v.score, 14)
    }

    func testAimPointFollowsTheLineAndItsRight() throws {
        var m = Mission(number: 1, from: nil, lockedRange: 20, bearing: 90)
        XCTAssertEqual(m.aimPoint.east, 20, accuracy: 1e-9)
        XCTAssertEqual(m.aimPoint.north, 0, accuracy: 1e-9)
        m.fireControl.record(Spot(call: .short, lateral: -1)) // landed left: aim right (south when facing east)
        XCTAssertEqual(m.aimPoint.east, 22, accuracy: 1e-9)
        XCTAssertEqual(m.aimPoint.north, -1, accuracy: 1e-9)
    }

    // MARK: Scorecard

    private func course() -> Course {
        let flag = Flag(position: Geo.offset(origin, east: 0, north: 30), poleHeightM: 2.438, leanDeg: 0.2)
        let holes = [
            Hole(number: 1, name: "One", par: 3, firingPoints: [origin], flag: flag),
            Hole(number: 2, name: "Two", par: 4, downrangePlay: true, firingPoints: [origin], flag: flag)
        ]
        let box = GeoPolygon([Geo.offset(origin, east: -200, north: -200), Geo.offset(origin, east: 200, north: -200),
                              Geo.offset(origin, east: 200, north: 200), Geo.offset(origin, east: -200, north: 200)])
        return Course(format: 1, id: "t", name: "Test", version: 2, boundary: box, holes: holes)
    }

    func testScorecardTotalsAndNextHole() throws {
        var card = Scorecard(course: course(), player: "Me", practice: true)
        XCTAssertEqual(card.nextHole, 1)
        XCTAssertEqual(card.totalPar, 7)
        var h = HolePlay(hole: course().holes[0])
        try h.begin(lockedRange: 30, bearing: 0, from: origin)
        try h.record(Spot(call: .short, lateral: 0))
        try h.record(Spot(call: .over, lateral: 0))
        try h.ceaseFire(closest: 2.25)
        card.record(h)                                         // not finished: ignored
        XCTAssertNil(card.holes[0].score)
        try h.finish()
        card.record(h)
        XCTAssertEqual(card.holes[0].score, 3.3)
        XCTAssertEqual(card.holes[0].rounds, 2)
        XCTAssertEqual(card.total, 3.3)
        XCTAssertEqual(card.toPar, 0.3)
        XCTAssertEqual(card.nextHole, 2)
        XCTAssertFalse(card.isComplete)
        let back = try JSONDecoder().decode(Scorecard.self, from: JSONEncoder().encode(card))
        XCTAssertEqual(back, card)
    }

    // MARK: Practice

    func testPracticeSpotCalls() {
        var p = PracticeRange(pole: Ground(0, 30), poleHeight: 2.438, wind: .calm, seed: 1)
        XCTAssertEqual(p.spot(rest: Ground(0, 35), from: .zero).call, .over)
        XCTAssertEqual(p.spot(rest: Ground(0, 25), from: .zero).call, .short)
        XCTAssertEqual(p.spot(rest: Ground(0, 30.1), from: .zero).call, .rangeCorrect)
        let s = p.spot(rest: Ground(2, 30), from: .zero)          // facing north, east is right
        XCTAssertEqual(s.lateral, 2, accuracy: 0.3)
    }

    func testPracticeLockIsCloseAtShortRange() {
        var p = PracticeRange(pole: Ground(30, 40), poleHeight: 2.438, wind: .calm, seed: 7)
        let l = p.lock(from: .zero)
        XCTAssertEqual(l.range, 50, accuracy: 4 * l.sigma)
        XCTAssertEqual(l.bearing, atan2(30, 40) * 180 / .pi, accuracy: 1e-9)
    }

    /// Plays whole practice holes the way the app does and checks fire control brings rounds in.
    func testPracticeHolesConverge() throws {
        var scores: [Double] = []
        for seed in UInt64(1)...40 {
            var range = PracticeRange(pole: Ground(10, 45), poleHeight: 2.438,
                                      wind: PracticeRange.randomWind(seed: seed), seed: seed)
            var h = HolePlay(holeNumber: 1, par: 4, inRadius: 1, downrangePlay: false)
            let lock = range.lock(from: .zero)
            try h.begin(lockedRange: lock.range, bearing: lock.bearing, from: nil)
            var closest = Double.infinity
            while !h.atRoundLimit {
                let aim = h.mission!.aimPoint(from: .zero)
                let table = Solver.table(target: aim, wind: .calm) // the player guesses calm
                guard let sol = InitialData.recommended(table) else { XCTFail("no solution"); return }
                let shot = range.fire(sol, from: .zero)
                closest = min(closest, range.distanceToPole(shot.rest))
                let spot = range.spot(rest: shot.rest, from: .zero)
                try h.record(spot)
                if closest <= 1 { break }
            }
            try h.ceaseFire(closest: closest)
            scores.append(try h.finish())
        }
        let mean = scores.reduce(0, +) / Double(scores.count)
        XCTAssertLessThan(mean, 8, "mean practice score \(mean)")
    }
}
