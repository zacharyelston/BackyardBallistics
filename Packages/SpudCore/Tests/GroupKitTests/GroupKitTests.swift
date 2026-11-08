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

    // MARK: A whole match

    /// Two squads play a two-hole practice match over the loopback: phones range, call Fired and
    /// spot; each commander gates and commits; the match host runs turns and the walking-out hold.
    func testTwoSquadPracticeMatch() throws {
        let f = Field()
        f.addSquad("Red")
        f.addSquad("Blue")
        // Members stand behind the firing point (the fan points north).
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(1, -1))      // Red's gunner (first to join)
        let ben = f.addPhone("Ben", squad: "Red", at: Ground(-4, -6))
        let cy = f.addPhone("Cy", squad: "Blue", at: Ground(2, -2))       // Blue's gunner
        let dee = f.addPhone("Dee", squad: "Blue", at: Ground(6, -8))
        XCTAssertNotNil(ana.member)
        XCTAssertEqual(f.hosts["Red"]!.round.squad.members.map(\.role), [.gunner, .member])
        f.hosts["Red"]!.designatedSpotter = ana.member
        f.hosts["Blue"]!.designatedSpotter = cy.member

        f.tick()
        f.matchAction { m, now in m.start(now: now) }
        f.tick()
        XCTAssertEqual(f.match.state.turn, Turn(hole: 1, squad: f.hosts["Red"]!.squadID))
        XCTAssertEqual(f.holds("Red"), [], "Red is on turn with no holds")
        XCTAssertEqual(f.holds("Blue"), [.notYourTurn])

        var order: [String] = []
        var seed: UInt64 = 1
        while let turn = f.match.state.turn {
            let name = f.hosts.first { $0.value.squadID == turn.squad }!.key
            let gunner = name == "Red" ? ana : cy
            let spotter = name == "Red" ? ben : dee
            order.append("\(name)\(turn.hole)")
            try playHole(f, squad: name, gunner: gunner, spotter: spotter, seed: seed)
            seed += 1
            f.tick()
        }

        XCTAssertEqual(order, ["Red1", "Blue1", "Red2", "Blue2"])
        XCTAssertTrue(f.match.state.finished)
        for name in ["Red", "Blue"] {
            let card = f.hosts[name]!.round.card
            XCTAssertTrue(card.isComplete)
            XCTAssertEqual(card.player, name)
            XCTAssertEqual(card.playerID, f.hosts[name]!.squadID.raw)
            XCTAssertEqual(f.match.state.total(f.hosts[name]!.squadID), card.total, accuracy: 1e-9)
            XCTAssertLessThan(card.total, 30, "fire control should bring rounds in")
        }
        // Members saw the squad's summary, with no firing data in it.
        XCTAssertEqual(ben.status?.squad.name, "Red")
        XCTAssertEqual(ben.status?.total, f.hosts["Red"]!.round.card.total)
        XCTAssertTrue(f.hosts["Red"]!.incidents.isEmpty, "\(f.hosts["Red"]!.incidents)")
    }

    /// One squad's turn at a hole, the way the commander's iPad and the phones would play it.
    private func playHole(_ f: Field, squad: String, gunner: Phone, spotter: Phone, seed: UInt64) throws {
        let other = squad == "Red" ? "Blue" : "Red"
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
            XCTAssertFalse(display(f, other).isShown, "the other squad must never see firing data on our turn")

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

        // Cease fire: everyone walks out, and every squad is held.
        f.command(squad) { $0.ceaseFire(now: $1) }
        f.tick()
        XCTAssertTrue(f.holds(other).contains(.walkingOut(f.hosts[squad]!.squadID)))
        XCTAssertFalse(display(f, squad).isShown)

        // Verify: the gunner ranges the pole from the closest round.
        let verify = LockReport(purpose: .verify, lock: reticleLock(range.lock(from: closest.at), from: closest.at,
                                                                    poleHeight: hole.flag.poleHeightM))
        f.send(gunner, .lock(verify))
        f.command(squad) { $0.useLock(verify.id, now: $1) }
        XCTAssertEqual(f.hosts[squad]!.round.hole?.phase, .ceased, f.hosts[squad]!.lastProblem ?? "")
        f.command(squad) { $0.finish(now: $1) }
        f.tick()
        XCTAssertFalse(f.holds(other).contains(.walkingOut(f.hosts[squad]!.squadID)))
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

    func testMemberInTheFanHoldsEveryone() {
        let f = Field()
        f.addSquad("Red")
        f.addSquad("Blue")
        f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        let dee = f.addPhone("Dee", squad: "Blue", at: Ground(5, -5))
        f.tick()
        f.matchAction { m, now in m.start(now: now) }
        f.command("Red") { $0.startNextHole(now: $1) }   // Red's fan now points at hole 1's flag
        f.tick()
        XCTAssertEqual(f.holds("Red"), [])

        dee.at = Ground(6, 25)          // Blue's member wanders out toward Red's flag
        f.tick()
        let hold = Hold.memberInFan(dee.member!, name: "Dee")
        XCTAssertTrue(f.holds("Red").contains(hold))
        XCTAssertTrue(f.holds("Blue").contains(hold))

        dee.at = Ground(40, -10)        // off to the side, behind the line
        f.tick()
        XCTAssertFalse(f.holds("Red").contains(hold))
    }

    func testFanGeometry() {
        let fan = Fan(origin: origin, bearing: 0)
        func at(_ e: Double, _ n: Double, acc: Double = 1) -> Bool {
            MatchHost.inFan(MemberPosition(at: geo(Ground(e, n)), accuracy: acc, time: Date()), fan)
        }
        XCTAssertTrue(at(0, 30))
        XCTAssertTrue(at(15, 30))           // 26.6°, inside ±30°
        XCTAssertFalse(at(25, 30))          // 39.8°
        XCTAssertTrue(at(25, 30, acc: 8))   // the accuracy circle reaches into the fan
        XCTAssertFalse(at(0, -20))          // behind
        XCTAssertFalse(at(0, 3))            // at the firing point
        XCTAssertFalse(at(0, 120))          // past the fan's radius
    }

    func testCheckFireHoldsAllAndNeedsAFreshLookDownrange() {
        let f = Field()
        f.addSquad("Red")
        f.addSquad("Blue")
        f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        let dee = f.addPhone("Dee", squad: "Blue", at: Ground(5, -5))
        f.tick()
        f.matchAction { m, now in m.start(now: now) }
        f.command("Red") { $0.startNextHole(now: $1) }
        f.command("Red") { $0.confirmDownrange(now: $1) }
        XCTAssertTrue(f.hosts["Red"]!.isDownrangeConfirmed())

        f.send(dee, .checkFire(CheckFire(by: "Dee")))
        XCTAssertTrue(f.holds("Blue").contains(.checkFire(by: "Dee")))
        XCTAssertTrue(f.holds("Red").contains(.checkFire(by: "Dee")), "Blue's commander forwarded it to the match")
        XCTAssertFalse(f.hosts["Red"]!.isDownrangeConfirmed(), "check fire withdraws every downrange confirmation")

        f.matchAction { m, now in m.withdrawCheckFire(now: now) }
        f.tick()
        XCTAssertFalse(f.holds("Red").contains(.checkFire(by: "Dee")))
        XCTAssertFalse(f.hosts["Red"]!.isDownrangeConfirmed(), "only the commander's own tap confirms again")
    }

    func testLostMatchHostAndSilentPhonesHold() {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        f.tick()
        f.matchAction { m, now in m.start(now: now) }
        f.tick()
        XCTAssertEqual(f.holds("Red"), [])

        ana.reportsPosition = false
        f.tick(MatchHost.positionTimeout + 1)
        XCTAssertTrue(f.holds("Red").contains(.positionUnknown(ana.member!, name: "Ana")))
        ana.reportsPosition = true
        f.tick()
        XCTAssertEqual(f.holds("Red"), [])

        f.net.down.insert(f.matchPeer)
        f.tick(SquadHost.matchHostTimeout + 1)
        XCTAssertTrue(f.holds("Red").contains(.matchHostLost))
    }

    func testNoMatchMeansNoFiringData() {
        let f = Field()
        f.addSquad("Solo", joinMatch: false)
        XCTAssertEqual(f.holds("Solo"), [.noMatch, .notYourTurn])
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

        // A squad on another version of the course is kept out.
        f.addSquad("Blue", course: testCourse(version: 2))
        XCTAssertEqual(f.match.state.squads.map(\.name), ["Red"])
    }

    // MARK: Spots

    func testAmendingASpotReplaysFireControl() throws {
        let f = Field()
        f.addSquad("Red")
        let ana = f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
        f.tick()
        f.matchAction { m, now in m.start(now: now) }
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
        // The round was fired with no match: logged.
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
        f.addSquad("Red", joinMatch: false)
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
}
