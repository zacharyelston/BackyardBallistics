import Foundation
import XCTest
import CoreGeo
import SafetyKit
import RangingKit
import BallisticsKit
import CourseKit
import RoundKit
@testable import GroupKit

final class GroupKitTests: XCTestCase {

    // MARK: A whole round

    /// A squad plays a two-hole practice round over the loopback: phones range, call Fired and
    /// spot; the commander gates and commits; cease fire holds the squad while people walk out.
    func testSquadPlaysARound() throws {
        let f = Field()
        f.addSquad("Red")
        // Members stand behind the firing point (the fan points north).
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(1, -1))      // the gunner (first to join)
        let ben = f.addPhone("Ben", squad: "Red", at: Ground(-4, -6))
        XCTAssertNotNil(ana.member)
        XCTAssertEqual(f.hosts["Red"]!.round.squad.members.map(\.role), [.gunner, .member])
        f.hosts["Red"]!.designatedSpotter = ana.member

        f.tick()
        XCTAssertEqual(f.holds("Red"), [], "between holes, nothing holds the squad")
        for seed in UInt64(1)...2 {
            try playHole(f, squad: "Red", gunner: ana, spotter: ben, seed: seed)
            f.tick()
        }

        let card = f.hosts["Red"]!.round.card
        XCTAssertTrue(card.isComplete)
        XCTAssertEqual(card.player, "Red")
        XCTAssertEqual(card.playerID, f.hosts["Red"]!.squadID.raw)
        XCTAssertLessThan(card.total, 30, "fire control should bring rounds in")
        // Members saw the squad's summary, with no firing data in it.
        XCTAssertEqual(ben.status?.squad.name, "Red")
        XCTAssertEqual(ben.status?.total, card.total)
        XCTAssertTrue(f.hosts["Red"]!.incidents.isEmpty, "\(f.hosts["Red"]!.incidents)")
    }

    /// One hole, the way the commander's iPad and the phones would play it.
    private func playHole(_ f: Field, squad: String, gunner: Phone, spotter: Phone, seed: UInt64) throws {
        f.command(squad) { $0.startNextHole(now: $1) }
        let hole = f.hosts[squad]!.round.currentHole!
        var range = PracticeRange(pole: ground(hole.flag.position), poleHeight: hole.flag.poleHeightM,
                                  wind: PracticeRange.randomWind(seed: seed), seed: seed)

        // The gunner ranges from the firing point; the commander gates it and begins the mission.
        let lock = LockReport(purpose: .initial, lock: reticleLock(range.lock(from: .zero), from: .zero, poleHeight: hole.flag.poleHeightM))
        f.send(gunner, .lock(lock))
        XCTAssertEqual(gunner.receipts.last?.status, .received)
        f.command(squad) { $0.useLock(lock.id, now: $1) }
        XCTAssertEqual(gunner.receipts.last?.status, .used, f.hosts[squad]!.lastProblem ?? "")
        XCTAssertEqual(f.hosts[squad]!.round.hole?.phase, .firing)

        // Before the commander's own look downrange, SafetyKit blocks.
        XCTAssertEqual(display(f, squad).safetyReasons, [.downrangeNotConfirmed])
        f.command(squad) { $0.confirmDownrange(now: $1) }

        var closest = (d: Double.infinity, at: Ground.zero)
        while true {
            let host = f.hosts[squad]!
            let h = host.round.hole!
            guard !h.atRoundLimit else { break }
            let shown = display(f, squad)
            guard case let .show(cleared) = shown else { return XCTFail("blocked: \(shown.safetyReasons) \(shown.holds)") }

            let shot = range.fire(cleared.value, from: .zero)
            f.send(gunner, .fired(FiredReport(hole: h.holeNumber, mission: h.mission!.number, round: h.roundsFired + 1)))
            XCTAssertEqual(spotter.spotRequests.last?.round, h.roundsFired + 1)
            let d = range.distanceToPole(shot.rest)
            if d < closest.d { closest = (d, shot.rest) }

            // The spotter's call arrives first and waits; the gunner is the designated spotter and commits.
            let req = spotter.spotRequests.last!
            let s1 = range.spot(rest: shot.rest, from: .zero)
            f.send(spotter, .spot(SpotReport(hole: req.hole, mission: req.mission, round: req.round, call: s1.call, lateral: nil)))
            XCTAssertEqual(f.hosts[squad]!.round.hole!.roundsFired, req.round - 1, "an undesignated call waits for the commander")
            let s2 = range.spot(rest: shot.rest, from: .zero)
            f.send(gunner, .spot(SpotReport(hole: req.hole, mission: req.mission, round: req.round, call: s2.call, lateral: s2.lateral)))
            XCTAssertEqual(f.hosts[squad]!.round.hole!.roundsFired, req.round)
            f.tick()
            if closest.d <= hole.flag.inRadiusM { break }
        }

        // Cease fire: everyone walks out, and the squad is held.
        f.command(squad) { $0.ceaseFire(now: $1) }
        f.tick()
        XCTAssertTrue(f.holds(squad).contains(.walkingOut))
        XCTAssertFalse(display(f, squad).isShown)

        // Verify: the gunner ranges the pole from the closest round.
        let verify = LockReport(purpose: .verify, lock: reticleLock(range.lock(from: closest.at), from: closest.at,
                                                                    poleHeight: hole.flag.poleHeightM))
        f.send(gunner, .lock(verify))
        f.command(squad) { $0.useLock(verify.id, now: $1) }
        XCTAssertEqual(f.hosts[squad]!.round.hole?.phase, .ceased, f.hosts[squad]!.lastProblem ?? "")
        f.command(squad) { $0.finish(now: $1) }
        f.tick()
        XCTAssertFalse(f.holds(squad).contains(.walkingOut))
    }

    /// The commander's solution for the current mission, through SafetyKit and the squad's holds.
    private func display(_ f: Field, _ squad: String) -> FiringDisplay<Solution> {
        let host = f.hosts[squad]!
        guard let h = host.round.hole, let m = h.mission, let hole = host.round.currentHole else {
            return .blocked(safety: [], holds: [])
        }
        let aim = m.aimPoint(from: ground(m.from ?? hole.firingPoints[0]))
        let sol = InitialData.recommended(Solver.table(target: aim, wind: .calm))!
        let verdict = Safety.clearSolution(sol, distance: m.fireControl.aimRange, muzzleVelocity: sol.charge.velocity,
                                           launcher: conformingLauncher(round: host.round.card.id.uuidString),
                                           roundID: host.round.card.id.uuidString, downrange: host.round.downrange,
                                           player: host.player, hole: h.holeNumber)
        return host.firingDisplay(verdict, now: f.now)
    }

    // MARK: Holds

    func testMemberInTheFanHoldsTheSquad() {
        let f = Field()
        f.addSquad("Red")
        f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        let ben = f.addPhone("Ben", squad: "Red", at: Ground(5, -5))
        f.tick()
        f.command("Red") { $0.startNextHole(now: $1) }   // the fan now points at hole 1's flag
        f.tick()
        XCTAssertEqual(f.holds("Red"), [])

        ben.at = Ground(6, 25)          // Ben wanders out toward the flag
        f.tick()
        let hold = Hold.memberInFan(ben.member!, name: "Ben")
        XCTAssertTrue(f.holds("Red").contains(hold))

        ben.at = Ground(40, -10)        // off to the side, behind the line
        f.tick()
        XCTAssertFalse(f.holds("Red").contains(hold))
    }

    func testFanGeometry() {
        let fan = Fan(origin: origin, bearing: 0)
        func at(_ e: Double, _ n: Double, acc: Double = 1) -> Bool {
            SquadHost.inFan(MemberPosition(at: geo(Ground(e, n)), accuracy: acc, time: Date()), fan)
        }
        XCTAssertTrue(at(0, 30))
        XCTAssertTrue(at(15, 30))           // 26.6°, inside ±30°
        XCTAssertFalse(at(25, 30))          // 39.8°
        XCTAssertTrue(at(25, 30, acc: 8))   // the accuracy circle reaches into the fan
        XCTAssertFalse(at(0, -20))          // behind
        XCTAssertFalse(at(0, 3))            // at the firing point
        XCTAssertFalse(at(0, 120))          // past the fan's radius
    }

    func testCheckFireHoldsAndNeedsAFreshLookDownrange() {
        let f = Field()
        f.addSquad("Red")
        f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        let ben = f.addPhone("Ben", squad: "Red", at: Ground(5, -5))
        f.tick()
        f.command("Red") { $0.startNextHole(now: $1) }
        f.command("Red") { $0.confirmDownrange(now: $1) }
        XCTAssertTrue(f.hosts["Red"]!.isDownrangeConfirmed())

        f.send(ben, .checkFire(CheckFire(by: "Ben")))
        XCTAssertTrue(f.holds("Red").contains(.checkFire(by: "Ben")))
        XCTAssertFalse(f.hosts["Red"]!.isDownrangeConfirmed(), "check fire withdraws the downrange confirmation")

        f.command("Red") { $0.withdrawCheckFire(now: $1) }
        f.tick()
        XCTAssertFalse(f.holds("Red").contains(.checkFire(by: "Ben")))
        XCTAssertFalse(f.hosts["Red"]!.isDownrangeConfirmed(), "only the commander's own tap confirms again")
    }

    func testSilentPhoneHoldsWhileAHoleIsLive() {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        f.tick()
        ana.reportsPosition = false
        f.tick(SquadHost.positionTimeout + 1)
        XCTAssertEqual(f.holds("Red"), [], "between holes nobody is held for a quiet phone")

        f.command("Red") { $0.startNextHole(now: $1) }
        XCTAssertTrue(f.holds("Red").contains(.positionUnknown(ana.member!, name: "Ana")), "silence is not clear")
        ana.reportsPosition = true
        f.tick()
        XCTAssertEqual(f.holds("Red"), [])
    }

    // MARK: Joining

    func testJoinCodesCourseAndRejoin() {
        let f = Field()
        f.addSquad("Red")
        let eve = f.addPhone("Eve", squad: "Red", at: .zero, code: "WRONG")
        XCTAssertNil(eve.member)
        XCTAssertEqual(eve.refusals, ["Wrong join code."])
        f.send(eve, .checkFire(CheckFire(by: "Eve")))
        XCTAssertFalse(f.holds("Red").contains(.checkFire(by: "Eve")), "a phone that hasn't joined is ignored")

        let ana = f.addPhone("Ana", squad: "Red", at: .zero)
        let first = ana.member
        f.send(ana, .bye)
        f.send(ana, .hello(Hello(name: "Ana", device: ana.device, joinCode: "RED")))
        XCTAssertEqual(ana.member, first, "same phone, same member")
        XCTAssertEqual(f.hosts["Red"]!.round.squad.members.map(\.name), ["Ana"], "Eve never joined; Ana is listed once")

    }

    // MARK: Spots

    func testAmendingASpotReplaysFireControl() throws {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        f.tick()
        f.command("Red") { $0.startNextHole(now: $1) }
        let hole = f.hosts["Red"]!.round.currentHole!
        var range = PracticeRange(pole: ground(hole.flag.position), poleHeight: hole.flag.poleHeightM, wind: .calm, seed: 3)
        let lock = LockReport(purpose: .initial, lock: reticleLock(range.lock(from: .zero), from: .zero, poleHeight: hole.flag.poleHeightM))
        f.send(ana, .lock(lock))
        f.command("Red") { $0.useLock(lock.id, now: $1) }
        for call in [RangeCall.short, .over] {
            f.command("Red") { $0.fired(now: $1) }
            f.command("Red") { $0.commit(Spot(call: call, lateral: 1), now: $1) }
        }
        let before = f.hosts["Red"]!.round.hole!
        f.command("Red") { $0.amend(round: 1, to: Spot(call: .over, lateral: 1), now: $1) }
        let after = f.hosts["Red"]!.round.hole!
        XCTAssertEqual(after.rounds.map { $0.spot?.call }, [.over, .over])
        XCTAssertNotEqual(after.mission!.fireControl, before.mission!.fireControl)
        XCTAssertEqual(after, try SquadRound.replay(f.hosts["Red"]!.round.events, hole: hole))
    }

    func testSpotsOnlyForTheRoundInFlight() {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        f.command("Red") { $0.startNextHole(now: $1) }
        let hole = f.hosts["Red"]!.round.currentHole!
        var range = PracticeRange(pole: ground(hole.flag.position), poleHeight: hole.flag.poleHeightM, wind: .calm, seed: 4)
        let lock = LockReport(purpose: .initial, lock: reticleLock(range.lock(from: .zero), from: .zero, poleHeight: hole.flag.poleHeightM))
        f.send(ana, .lock(lock))
        f.command("Red") { $0.useLock(lock.id, now: $1) }
        f.hosts["Red"]!.designatedSpotter = ana.member

        f.send(ana, .spot(SpotReport(hole: 1, mission: 1, round: 1, call: .over, lateral: 0)))
        XCTAssertEqual(f.hosts["Red"]!.round.hole!.roundsFired, 0, "no round in flight yet")
        f.send(ana, .fired(FiredReport(hole: 1, mission: 1, round: 2)))
        XCTAssertNil(f.hosts["Red"]!.roundInFlight, "Fired for the wrong round is ignored")
        f.send(ana, .fired(FiredReport(hole: 1, mission: 1, round: 1)))
        f.send(ana, .spot(SpotReport(hole: 1, mission: 1, round: 2, call: .over, lateral: 0)))
        XCTAssertEqual(f.hosts["Red"]!.round.hole!.roundsFired, 0, "a spot for another round is ignored")
        f.send(ana, .spot(SpotReport(hole: 1, mission: 1, round: 1, call: .over, lateral: 0.4)))
        XCTAssertEqual(f.hosts["Red"]!.round.hole!.roundsFired, 1)
        // The round was fired while held (no position from Ana yet): logged.
        XCTAssertEqual(f.hosts["Red"]!.incidents.count, 1)
    }

    func testAFlagMissIsRefusedWithReasons() {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: .zero)
        f.command("Red") { $0.startNextHole(now: $1) }
        let hole = f.hosts["Red"]!.round.currentHole!
        // Ranged a tree 30 m east of the flag.
        let wrong = Ground(38, 40)
        let lock = LockReport(purpose: .initial, lock: reticleLock(((wrong.x * wrong.x + wrong.y * wrong.y).squareRoot(), Geo.degrees(atan2(wrong.x, wrong.y)), 0.1),
                                                                   from: .zero, poleHeight: hole.flag.poleHeightM))
        f.send(ana, .lock(lock))
        f.command("Red") { $0.useLock(lock.id, now: $1) }
        XCTAssertEqual(ana.receipts.last?.status, .refused)
        XCTAssertTrue(ana.receipts.last?.reasons.first?.contains("from the published flag") == true)
        XCTAssertEqual(f.hosts["Red"]!.round.hole?.phase, .setup)
    }

    // MARK: Observers (v4 Theater)

    func testAnObserverWatchesButCantAct() {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        f.tick()
        let theater = Phone("Theater", at: .zero)
        theater.commander = Field.ipad("Red")
        var watched: [GroupMessage.Body] = []
        f.net.add(theater.peer) { m, _ in watched.append(m.body); return [] }
        f.send(theater, .hello(Hello(name: "Theater", device: UUID(), joinCode: "RED", role: .observer)))
        guard case let .observing(squad)? = watched.first else { return XCTFail("\(watched)") }
        XCTAssertEqual(squad.members.map(\.name), ["Ana"], "an observer isn't added to the roster")
        XCTAssertTrue(watched.contains(.course(f.course)), "the observer gets the course for its site map")
        XCTAssertTrue(watched.contains { if case .positions = $0 { return true }; return false }, "known positions on joining")

        // Live positions and status reach it.
        watched = []
        ana.at = Ground(3, -4)
        f.tick()
        XCTAssertTrue(watched.contains { if case .positions = $0 { return true }; return false })

        // Nothing it sends acts on the squad.
        f.command("Red") { $0.startNextHole(now: $1) }
        let before = f.hosts["Red"]!.round
        for body: GroupMessage.Body in [.checkFire(CheckFire(by: "Theater")), .fired(FiredReport(hole: 1, mission: 1, round: 1)),
                                        .position(MemberPosition(at: origin, accuracy: 1, time: f.now))] {
            f.send(theater, body)
        }
        XCTAssertEqual(f.hosts["Red"]!.round, before)
        XCTAssertFalse(f.holds("Red").contains(.checkFire(by: "Theater")))
        XCTAssertFalse(watched.contains { if case .spotRequest = $0 { return true }; return false })
    }

    // MARK: Orders

    func testOrdersReachTheirMembersAndAnswersCount() {
        let f = Field()
        f.addSquad("Red")
        var got: [String: [Order]] = [:]
        var phones: [String: Phone] = [:]
        for name in ["Ana", "Ben", "Cy"] {
            let p = f.addPhone(name, squad: "Red", at: .zero)
            phones[name] = p
            f.net.add(p.peer) { m, from in
                if case let .order(o) = m.body { got[name, default: []].append(o) }
                return p.receive(m, from: from)
            }
        }
        let ben = phones["Ben"]!.member!, cy = phones["Cy"]!.member!

        // To one member.
        f.command("Red") { $0.sendOrder(.moveTo, text: "Left flank", at: origin, to: [ben], now: $1) }
        XCTAssertEqual(got["Ben"]?.map(\.text), ["Left flank"])
        XCTAssertNil(got["Ana"])
        XCTAssertNil(got["Cy"])

        // To the team.
        f.command("Red") { $0.sendOrder(.holdPosition, text: "Hold, people downrange", now: $1) }
        XCTAssertEqual(got.values.map(\.count).sorted(), [1, 1, 2])

        // Answers: only from someone the order was for.
        let flank = got["Ben"]![0]
        f.send(phones["Ben"]!, .orderAck(OrderAck(order: flank.id, response: .done)))
        f.send(phones["Cy"]!, .orderAck(OrderAck(order: flank.id, response: .done)))
        XCTAssertEqual(f.hosts["Red"]!.acks[flank.id], [ben: .done])
        XCTAssertEqual(f.hosts["Red"]!.recipients(of: flank).map(\.name), ["Ben"])

        // A rejoin gets its unfinished orders again; a finished one isn't resent.
        got["Cy"] = []
        f.send(phones["Cy"]!, .bye)
        f.send(phones["Cy"]!, .hello(Hello(name: "Cy", device: phones["Cy"]!.device, joinCode: "RED")))
        XCTAssertEqual(got["Cy"]?.map(\.kind), [.holdPosition])
        got["Ben"] = []
        f.send(phones["Ben"]!, .bye)
        f.send(phones["Ben"]!, .hello(Hello(name: "Ben", device: phones["Ben"]!.device, joinCode: "RED")))
        XCTAssertEqual(got["Ben"]?.map(\.kind), [.holdPosition], "the done move-to isn't resent")

        // An order to nobody on the roster is refused; long text is cut.
        f.command("Red") { $0.sendOrder(.note, text: "x", to: [MemberID()], now: $1) }
        XCTAssertEqual(f.hosts["Red"]!.lastProblem, "Pick at least one member.")
        XCTAssertEqual(Order(kind: .note, text: String(repeating: "a", count: 500), time: Date()).text.count, Order.maxText)
        _ = cy
    }

    // MARK: Field notes and new fields through the squad

    func testNotesGoToTheLeaderAndOnToObservers() {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: .zero)
        var watched: [GroupMessage.Body] = []
        let theater = Phone("Theater", at: .zero)
        theater.commander = Field.ipad("Red")
        f.net.add(theater.peer) { m, _ in watched.append(m.body); return [] }
        f.send(theater, .hello(Hello(name: "Theater", device: UUID(), joinCode: "RED", role: .observer)))

        f.send(ana, .fieldNote(FieldNote(author: "someone else", time: f.now, courseID: "squad-test", text: "Mole hill by hole 2")))
        XCTAssertEqual(f.hosts["Red"]!.notes.map(\.author), ["Ana"], "the author is the member, not what the note says")
        XCTAssertTrue(watched.contains { if case let .fieldNote(n) = $0 { return n.text == "Mole hill by hole 2" }; return false })
    }

    func testAMembersFieldIsAdoptedBetweenHolesOnly() {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: .zero)
        var watched: [GroupMessage.Body] = []
        let theater = Phone("Theater", at: .zero)
        theater.commander = Field.ipad("Red")
        f.net.add(theater.peer) { m, _ in watched.append(m.body); return [] }
        f.send(theater, .hello(Hello(name: "Theater", device: UUID(), joinCode: "RED", role: .observer)))
        var receipts: [Receipt] = []
        f.net.add(ana.peer) { m, from in if case let .receipt(r) = m.body { receipts.append(r) }; return ana.receive(m, from: from) }

        var newCourse = testCourse(version: 1)
        newCourse.id = "orchard"
        newCourse.name = "The Orchard"
        let sub = FieldSubmission(author: "Ana", time: f.now, course: newCourse)
        f.send(ana, .fieldSubmission(sub))
        XCTAssertEqual(receipts.last?.status, .received)
        XCTAssertEqual(f.hosts["Red"]!.submissions.map(\.course.id), ["orchard"])

        // Mid-hole: refused.
        f.command("Red") { $0.startNextHole(now: $1) }
        var range = PracticeRange(pole: ground(f.course.holes[0].flag.position), poleHeight: 2.438, wind: .calm, seed: 1)
        let lock = LockReport(purpose: .initial, lock: reticleLock(range.lock(from: .zero), from: .zero, poleHeight: 2.438))
        f.send(ana, .lock(lock))
        f.command("Red") { $0.useLock(lock.id, now: $1) }
        f.command("Red") { $0.adoptField(sub.id, now: $1) }
        XCTAssertEqual(f.hosts["Red"]!.round.course.id, "squad-test")
        XCTAssertEqual(f.hosts["Red"]!.lastProblem, "Finish or end hole 1 first.")

        // A fresh squad between holes: adopted; observers get the course; Ana hears it's in play.
        f.hosts["Red"] = SquadHost(round: SquadRound(squad: f.hosts["Red"]!.round.squad, course: f.course, practice: true), joinCode: "RED")
        f.send(ana, .hello(Hello(name: "Ana", device: ana.device, joinCode: "RED")))
        f.send(theater, .hello(Hello(name: "Theater", device: UUID(), joinCode: "RED", role: .observer)))
        f.send(ana, .fieldSubmission(sub))
        watched = []
        f.command("Red") { $0.adoptField(sub.id, now: $1) }
        XCTAssertEqual(f.hosts["Red"]!.round.course.id, "orchard")
        XCTAssertEqual(f.hosts["Red"]!.round.card.courseID, "orchard")
        XCTAssertEqual(f.hosts["Red"]!.round.squad.members.map(\.name), ["Ana"], "the squad keeps its members")
        XCTAssertTrue(watched.contains(.course(newCourse)), "the Theater hears of the new field")
        XCTAssertEqual(receipts.last?.status, .stored)
        XCTAssertTrue(f.hosts["Red"]!.submissions.isEmpty)
    }

    func testAContributorIsPointedAtTheTheater() {
        let f = Field()
        f.addSquad("Red")
        let p = f.addPhone("Ana", squad: "Red", at: .zero)
        p.member = nil
        p.refusals = []
        f.send(p, .hello(Hello(name: "Ana", device: UUID(), joinCode: "RED", role: .contributor)))
        XCTAssertTrue(p.refusals.last?.contains("Send to Theater") == true)
    }

    /// Adopting a practice-only field (here, its firing point is past the 100 yd limit) puts the squad
    /// in practice, so no real round can be fired on it.
    func testAdoptingAPracticeOnlyFieldPutsTheSquadInPractice() {
        let f = Field()
        let live = SquadHost(squad: Squad(name: "Red"), course: f.course, practice: false, joinCode: "RED")
        f.hosts["Red"] = live
        f.net.add(Field.ipad("Red")) { [unowned f] m, from in f.hosts["Red"]!.handle(m, from: from, now: f.now) }
        let ana = f.addPhone("Ana", squad: "Red", at: .zero)
        var far = testCourse()
        far.id = "far"
        far.holes[0].flag.position = geo(Ground(0, 100))
        let sub = FieldSubmission(author: "Ana", time: f.now, course: far)
        f.send(ana, .fieldSubmission(sub))
        XCTAssertEqual(f.hosts["Red"]!.submissions.count, 1, "a practice-only field is accepted, not refused")
        XCTAssertFalse(f.hosts["Red"]!.round.practice)
        f.command("Red") { $0.adoptField(sub.id, now: $1) }
        XCTAssertEqual(f.hosts["Red"]!.round.course.id, "far")
        XCTAssertTrue(f.hosts["Red"]!.round.practice)
        XCTAssertTrue(f.hosts["Red"]!.round.card.practice)
    }

    func testLocksAreCheckedAgainstTheLegsTarget() throws {
        let o = origin
        let hole = Hole(number: 1, name: "Long", par: 6, firingPoints: [o],
                        layups: [Layup(position: geo(Ground(0, 80)), poleHeightM: 2.0)],
                        flag: Flag(position: geo(Ground(0, 160)), poleHeightM: 2.438, leanDeg: 0.1))
        var play = HolePlay(hole: hole)
        XCTAssertEqual(SquadHost.target(for: .initial, hole: hole, play: play).poleHeightM, 2.0, "first leg: the layup")
        try play.begin(lockedRange: 80, bearing: 0, from: o)
        XCTAssertFalse(SquadHost.target(for: .verify, hole: hole, play: play).isFlag)
        XCTAssertTrue(SquadHost.target(for: .nextMission, hole: hole, play: play).isFlag, "next leg: the flag")
    }
}
