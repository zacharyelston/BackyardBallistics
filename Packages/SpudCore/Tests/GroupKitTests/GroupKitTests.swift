import XCTest
import CoreGeo
import SafetyKit
import RangingKit
import BallisticsKit
import CourseKit
import RoundKit
@testable import GroupKit

// MARK: Fixtures

enum Fixture {
    static let origin = GeoPoint(latitude: 42.36, longitude: -71.058)
    static let poleHeight = 2.438

    /// Two holes from one firing point: hole 1's flag 30 m north, hole 2's 40 m east.
    static func course() -> Course {
        let holes = [
            Hole(number: 1, name: "North", par: 4, firingPoints: [origin],
                 flag: Flag(position: Geo.offset(origin, east: 0, north: 30), poleHeightM: poleHeight, leanDeg: 0.2)),
            Hole(number: 2, name: "East", par: 4, firingPoints: [origin],
                 flag: Flag(position: Geo.offset(origin, east: 40, north: 0), poleHeightM: poleHeight, leanDeg: 0.2))
        ]
        let box = GeoPolygon([Geo.offset(origin, east: -200, north: -200), Geo.offset(origin, east: 200, north: -200),
                              Geo.offset(origin, east: 200, north: 200), Geo.offset(origin, east: -200, north: 200)])
        return Course(format: 1, id: "test", name: "Test", version: 3, boundary: box, holes: holes)
    }

    /// A launcher that passes the Launcher standard for `round`, as SafetyKit's own tests build one.
    static func launcher(round: String) -> LauncherConformance {
        var c = LauncherConformance(launcherID: "E1", name: "Test sling", kind: .elastic)
        c.calibratedMaxVelocity = 30
        c.inspection = Inspection(roundID: round, results: Dictionary(uniqueKeysWithValues: InspectionItem.items(for: .elastic).map { ($0, true) }))
        return c
    }

    /// A lock taken at `from` on a pole at `range` metres and `bearing`, as the phone records it.
    static func lock(from: GeoPoint, range: Double, bearing: Double, poleHeight: Double = poleHeight) -> ReticleLock {
        ReticleLock(reticle: ReticleRange(focalPixels: 3000, poleHeight: poleHeight), range: range, bearing: bearing,
                    cameraHeight: 1.5, location: from, horizontalAccuracy: 3)
    }

    static func lock(at from: GeoPoint, on flag: GeoPoint) -> ReticleLock {
        lock(from: from, range: Geo.distance(from, flag), bearing: Geo.bearing(from: from, to: flag))
    }
}

/// A small loopback world: a match host, commanders and members, wired through `LoopbackNetwork`.
final class World {
    let net = LoopbackNetwork()
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var match: MatchHost?
    let matchDevice = DeviceID()
    var squads: [SquadID: SquadHost] = [:]
    var memberInbox: [DeviceID: [GroupMessage]] = [:]
    private var transports: [DeviceID: LoopbackTransport] = [:]

    init(withMatch: Bool = true) {
        if withMatch {
            match = MatchHost(course: Fixture.course(), device: matchDevice)
            let t = net.endpoint(matchDevice)
            transports[matchDevice] = t
            t.onReceive = { [unowned self] env in
                guard var m = self.match else { return }
                let out = m.receive(env.body, from: env.sender, now: self.now)
                self.match = m
                t.send(out)
            }
        }
    }

    func transport(_ d: DeviceID) -> LoopbackTransport { transports[d]! }

    @discardableResult
    func addSquad(_ name: String, members: [String]) -> (id: SquadID, commander: DeviceID, members: [Member]) {
        let commander = DeviceID()
        let squad = Squad(name: name, commander: commander)
        var host = SquadHost(squad: squad, course: Fixture.course(), practice: true, matchHost: match == nil ? nil : matchDevice)
        host.autoApprove = true
        squads[squad.id] = host
        let t = net.endpoint(commander)
        transports[commander] = t
        t.onReceive = { [unowned self] env in
            guard var h = self.squads[squad.id] else { return }
            let out = h.receive(env.body, from: env.sender, now: self.now)
            self.squads[squad.id] = h
            t.send(out)
        }
        t.send(host.registration())
        var list: [Member] = []
        for n in members {
            let d = DeviceID()
            let mt = net.endpoint(d)
            transports[d] = mt
            mt.onReceive = { [unowned self] env in self.memberInbox[d, default: []].append(env.body) }
            let id = MemberID()
            mt.send(.join(JoinRequest(member: id, name: n, courseID: "test", courseVersion: 3)), to: commander)
            list.append(Member(id: id, name: n, device: d))
        }
        net.deliver()
        return (squad.id, commander, list)
    }

    /// Runs a commander action and sends what it returns.
    func act(_ squad: SquadID, _ action: (inout SquadHost) throws -> [Outbound]) rethrows {
        var h = squads[squad]!
        let out = try action(&h)
        squads[squad] = h
        transport(h.device).send(out)
        net.deliver()
    }

    func actMatch(_ action: (inout MatchHost) -> [Outbound]) {
        var m = match!
        let out = action(&m)
        match = m
        transport(matchDevice).send(out)
        net.deliver()
    }

    func send(_ from: Member, _ message: GroupMessage, to commander: DeviceID) {
        transport(from.device).send(message, to: commander)
        net.deliver()
    }

    func position(_ m: Member, at p: GeoPoint, commander: DeviceID, accuracy: Double = 3) {
        send(m, .position(MemberPosition(member: m.id, at: p, accuracy: accuracy, time: now)), to: commander)
    }

    func gate(_ squad: SquadID) -> Gated<String>? {
        let h = squads[squad]!
        return h.firingData("solution", muzzleVelocity: 28, launcher: Fixture.launcher(round: "r"), roundID: "r", now: now)
    }
}

final class GroupKitTests: XCTestCase {

    // MARK: The match, end to end

    /// Two squads play a two-hole practice match over loopback: members range, fire, spot and verify;
    /// the commanders commit; the match host runs turns, the honour and the field-wide holds.
    func testTwoSquadPracticeMatch() throws {
        let w = World()
        let red = w.addSquad("Red", members: ["Ana", "Ben"])
        let blue = w.addSquad("Blue", members: ["Cy", "Di"])
        XCTAssertEqual(w.squads[red.id]!.squad.members.count, 2)
        XCTAssertEqual(w.match!.order, [red.id, blue.id])
        w.act(red.id) { $0.designatedSpotter = red.members[0].id; return [] }   // Red auto-accepts Ana's spots

        w.actMatch { $0.start(now: w.now) }
        var seed: UInt64 = 7
        var holeOrders: [[SquadID]] = []

        for holeNumber in 1...2 {
            holeOrders.append(w.match!.order)
            let course = Fixture.course()
            let hole = course.holes[holeNumber - 1]
            let fp = hole.firingPoints[0]
            let line = Geo.bearing(from: fp, to: hole.flag.position)
            // Gunners stand at the line; spotters 12 m off to each side, a little behind.
            func standAll() {
                for (s, side) in [(red, -1.0), (blue, 1.0)] {
                    w.position(s.members[0], at: Geo.destination(fp, bearing: line + 180, distance: 0.5), commander: s.commander)
                    w.position(s.members[1], at: Geo.destination(Geo.destination(fp, bearing: line + 90 * side, distance: 12),
                                                                 bearing: line + 180, distance: 2), commander: s.commander)
                }
            }
            standAll()

            for _ in 0..<2 {
                let shooterID = try XCTUnwrap(w.match!.current)
                let s = shooterID == red.id ? red : blue
                let other = shooterID == red.id ? blue : red
                try w.act(s.id) { try $0.startNextHole() }
                XCTAssertEqual(w.squads[s.id]!.hole?.holeNumber, holeNumber)

                // Range from the firing point: the iPad gates it with its own flag.
                w.send(s.members[0], .lock(LockReport(hole: holeNumber, purpose: .initial, lock: Fixture.lock(at: fp, on: hole.flag.position))), to: s.commander)
                XCTAssertEqual(w.squads[s.id]!.hole?.phase, .firing)

                // Not confirmed yet: SafetyKit holds it, whatever the group says.
                guard case let .held(safety, _)? = w.gate(s.id) else { return XCTFail("firing data shown before downrange") }
                XCTAssertTrue(safety.contains(.downrangeNotConfirmed))
                try w.act(s.id) { try $0.confirmDownrange() }
                XCTAssertTrue(w.gate(s.id)?.isShown == true, "\(String(describing: w.gate(s.id)))")
                XCTAssertNil(w.gate(other.id), "the other squad has no mission yet")

                var range = PracticeRange(pole: Ground(0, 0), poleHeight: Fixture.poleHeight, wind: Wind(speed: 0, fromBearing: 0), seed: seed)
                seed += 1
                let pole = Geo.eastNorth(of: hole.flag.position, from: fp)
                let poleG = Ground(pole.east, pole.north)
                range.pole = poleG
                var closest = Double.infinity
                var closestRest = Ground(0, 0)
                let bias = Ground(1.2, -2.0)

                for _ in 0..<6 {
                    let play = w.squads[s.id]!.hole!
                    let m = play.mission!
                    let aim = m.aimPoint(from: Ground(0, 0))
                    let rest = aim + bias + Ground(Double.random(in: -0.3...0.3), Double.random(in: -0.3...0.3))
                    w.send(s.members[0], .fired(hole: holeNumber, mission: m.number), to: s.commander)
                    let request = try XCTUnwrap(w.squads[s.id]!.awaiting)
                    XCTAssertTrue(w.memberInbox[s.members[1].device, default: []].contains(.spotRequest(request)))
                    let spot = range.spot(rest: rest, from: Ground(0, 0))
                    // Ana spots from the line; Ben sends an eye call only.
                    w.send(s.members[1], .spot(SpotReport(hole: holeNumber, mission: m.number, round: request.round, call: spot.call, lateral: nil)), to: s.commander)
                    w.send(s.members[0], .spot(SpotReport(hole: holeNumber, mission: m.number, round: request.round, call: spot.call, lateral: spot.lateral)), to: s.commander)
                    if s.id == blue.id {
                        XCTAssertEqual(w.squads[s.id]!.reports.count, 2)
                        try w.act(s.id) { try $0.commit(callFrom: s.members[1].id, lateralFrom: s.members[0].id) }
                    }
                    XCTAssertNil(w.squads[s.id]!.awaiting, "spot committed")
                    XCTAssertEqual(w.squads[s.id]!.hole!.roundsFired, request.round)
                    let d = range.distanceToPole(rest)
                    if d < closest { closest = d; closestRest = rest }
                    if d <= hole.flag.inRadiusM { break }
                }

                // Cease fire: the squad walks out, and the field is held for everyone.
                try w.act(s.id) { try $0.ceaseFire() }
                XCTAssertTrue(w.match!.holds(now: w.now).contains(.walkingOut(s.id)))
                XCTAssertTrue(w.squads[other.id]!.holds(now: w.now).contains(.walkingOut(s.id)))
                XCTAssertFalse(w.gate(s.id)?.isShown ?? false)

                // Verify: range the pole from the closest round.
                let restPoint = Geo.offset(fp, east: closestRest.x, north: closestRest.y)
                w.send(s.members[0], .lock(LockReport(hole: holeNumber, purpose: .verify, lock: Fixture.lock(at: restPoint, on: hole.flag.position))), to: s.commander)
                XCTAssertEqual(w.squads[s.id]!.hole!.verdict!.closest, closest, accuracy: 0.05)
                try w.act(s.id) { try $0.finishHole() }
                XCTAssertNotNil(w.match!.scores[s.id]?[holeNumber])
                standAll()
            }
        }

        let m = w.match!
        XCTAssertTrue(m.finished)
        XCTAssertNil(m.current)
        for id in [red.id, blue.id] {
            XCTAssertEqual(m.scores[id]?.count, 2)
            XCTAssertTrue(w.squads[id]!.card.isComplete)
            XCTAssertEqual(w.squads[id]!.card.playerID, id.raw)
        }
        // The honour: hole 2's order is hole 1's scores, lowest first.
        let s1 = m.scores.mapValues { $0[1]! }
        let expected = [red.id, blue.id].enumerated().sorted { s1[$0.element]! != s1[$1.element]! ? s1[$0.element]! < s1[$1.element]! : $0.offset < $1.offset }.map(\.element)
        XCTAssertEqual(holeOrders[1], expected)
        // Members saw the squad's view, which has no firing data in it.
        XCTAssertTrue(w.memberInbox[red.members[1].device]!.contains { if case .squadView = $0 { return true }; return false })
    }

    // MARK: Turns and lost links

    func testOnlyTheSquadWhoseTurnItIsMayShowFiringData() throws {
        let w = World()
        let red = w.addSquad("Red", members: ["Ana"])
        let blue = w.addSquad("Blue", members: ["Cy"])
        w.actMatch { $0.start(now: w.now) }
        let hole = Fixture.course().holes[0]
        for s in [red, blue] {
            w.position(s.members[0], at: Fixture.origin, commander: s.commander)
            try w.act(s.id) { try $0.startNextHole() }
            w.send(s.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: hole.flag.position))), to: s.commander)
            try w.act(s.id) { try $0.confirmDownrange() }
        }
        XCTAssertEqual(w.match!.current, red.id)
        XCTAssertTrue(w.gate(red.id)!.isShown)
        guard case let .held(safety, group)? = w.gate(blue.id) else { return XCTFail() }
        XCTAssertEqual(safety, [])
        XCTAssertEqual(group, [.notYourTurn])
    }

    func testStaleMemberAndLostMatchHostHold() throws {
        let w = World()
        let red = w.addSquad("Red", members: ["Ana", "Ben"])
        w.actMatch { $0.start(now: w.now) }
        let hole = Fixture.course().holes[0]
        let flank = Geo.offset(Fixture.origin, east: -12, north: -2)
        w.position(red.members[0], at: Fixture.origin, commander: red.commander)
        w.position(red.members[1], at: flank, commander: red.commander)
        try w.act(red.id) { try $0.startNextHole() }
        w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: hole.flag.position))), to: red.commander)
        try w.act(red.id) { try $0.confirmDownrange() }
        XCTAssertTrue(w.gate(red.id)!.isShown)

        // Ben's phone walks out of range: his position goes stale, and the match holds.
        w.net.cutLink(red.members[1].device, red.commander)
        w.now += GroupRules.positionStaleSeconds + 1
        w.position(red.members[0], at: Fixture.origin, commander: red.commander)
        XCTAssertTrue(w.squads[red.id]!.holds(now: w.now).contains(.memberPositionUnknown(red.members[1].id)))
        XCTAssertFalse(w.gate(red.id)!.isShown)

        // He's back: the hold lifts.
        w.net.healLink(red.members[1].device, red.commander)
        w.position(red.members[1], at: flank, commander: red.commander)
        XCTAssertTrue(w.gate(red.id)!.isShown)

        // The match host goes quiet: past the lease, the squad holds.
        w.net.cutLink(w.matchDevice, red.commander)
        w.now += GroupRules.matchLeaseSeconds + 1
        XCTAssertTrue(w.squads[red.id]!.holds(now: w.now).contains(.matchHostLost))
        XCTAssertFalse(w.gate(red.id)!.isShown)
        w.net.healLink(w.matchDevice, red.commander)
        w.position(red.members[0], at: Fixture.origin, commander: red.commander)
        w.position(red.members[1], at: flank, commander: red.commander)
        XCTAssertTrue(w.gate(red.id)!.isShown)
    }

    func testMemberInsideTheFanHoldsEveryone() throws {
        let w = World()
        let red = w.addSquad("Red", members: ["Ana", "Ben"])
        let blue = w.addSquad("Blue", members: ["Cy"])
        w.actMatch { $0.start(now: w.now) }
        let hole = Fixture.course().holes[0]
        w.position(red.members[0], at: Fixture.origin, commander: red.commander)
        w.position(red.members[1], at: Geo.offset(Fixture.origin, east: -12, north: -2), commander: red.commander)
        w.position(blue.members[0], at: Geo.offset(Fixture.origin, east: 2, north: 20), commander: blue.commander)   // downrange
        try w.act(red.id) { try $0.startNextHole() }
        w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: hole.flag.position))), to: red.commander)
        try w.act(red.id) { try $0.confirmDownrange() }
        guard case let .held(_, group)? = w.gate(red.id) else { return XCTFail("a member downrange must hold") }
        XCTAssertEqual(group, [.memberInFan(blue.members[0].id)])
        w.position(blue.members[0], at: Geo.offset(Fixture.origin, east: 15, north: -3), commander: blue.commander)
        XCTAssertTrue(w.gate(red.id)!.isShown)
    }

    func testFanGeometry() {
        let fp = Fixture.origin, flag = Geo.offset(fp, east: 0, north: 30)
        func inside(_ e: Double, _ n: Double, acc: Double = 3) -> Bool {
            FanCheck.mayBeInside(Geo.offset(fp, east: e, north: n), accuracy: acc, firingPoint: fp, flag: flag)
        }
        XCTAssertTrue(inside(0, 20))
        XCTAssertTrue(inside(20, 40))            // about 27° off the line
        XCTAssertFalse(inside(0, 2))             // at the line
        XCTAssertFalse(inside(0, -20))           // behind
        XCTAssertFalse(inside(30, 10))           // well off to the side
        XCTAssertTrue(inside(0, Safety.limits.fanRange + 2))   // just past the fan, but GPS could put them inside
        XCTAssertFalse(inside(0, Safety.limits.fanRange + 10))
    }

    // MARK: Safety

    func testClearedNeverCrossesTheWire() {
        XCTAssertNil(Cleared<Int>.self as? any Decodable.Type)
        XCTAssertNil(Cleared<Int>.self as? any Encodable.Type)
    }

    func testMessagesCarryNoFiringData() throws {
        let lock = Fixture.lock(at: Fixture.origin, on: Geo.offset(Fixture.origin, east: 0, north: 30))
        let samples: [GroupMessage] = [
            .join(JoinRequest(member: MemberID(), name: "A", courseID: "c", courseVersion: 1)),
            .position(MemberPosition(member: MemberID(), at: Fixture.origin, accuracy: 3, time: Date())),
            .lock(LockReport(hole: 1, purpose: .initial, lock: lock)),
            .spot(SpotReport(hole: 1, mission: 1, round: 1, call: .over, lateral: 0.4)),
            .fired(hole: 1, mission: 1), .checkFire(CheckFire(by: DeviceID())), .bye,
            .joined(Member(name: "A", device: DeviceID())), .refused(reason: "x"),
            .squadView(SquadView(revision: 1, squad: "Red", hole: 1, phase: .firing,
                                 rounds: [RoundLine(number: 1, mission: 1, call: .short, lateral: 1, addDrop: 2, rightLeft: -1, lost: false)],
                                 scores: [1: 4.2], yourTurn: true, holds: [.notYourTurn])),
            .spotRequest(SpotRequest(hole: 1, mission: 1, round: 1)), .ack(Ack(id: UUID(), applied: true, reason: nil)),
            .register(SquadEntry(squad: SquadID(), name: "Red", members: [MemberID()])),
            .squadStatus(SquadStatus(squad: SquadID(), revision: 1, hole: 1, phase: .ceased, firingPoint: 0, score: nil)),
            .memberPositions(squad: SquadID(), []), .checkFireRaised(CheckFire(by: DeviceID())),
            .matchView(MatchView(revision: 1, hole: 1, order: [], current: nil, scores: [:], holds: [.walkingOut(SquadID())],
                                 activeCheckFires: [], seenCheckFires: [], finished: false))
        ]
        let banned = ["elevation", "charge", "aimOffset", "timeOfFlight", "muzzleVelocity", "launcher", "solution", "cleared"]
        for m in samples {
            let env = Envelope(sender: DeviceID(), seq: 1, body: m)
            let data = try JSONEncoder().encode(env)
            XCTAssertEqual(try JSONDecoder().decode(Envelope.self, from: data), env)
            let json = String(decoding: data, as: UTF8.self).lowercased()
            for word in banned { XCTAssertFalse(json.contains("\"\(word.lowercased())"), "\(m) carries \(word)") }
        }
    }

    func testHoldsOnlyAdd() {
        let reasons: [SafetyReason] = [.downrangeNotConfirmed]
        let holdSets: [[Hold]] = [[], [.notYourTurn], [.checkFire(by: DeviceID())], [.matchHostLost, .walkingOut(SquadID())]]
        for holds in holdSets {
            let blocked = Safety.clearSolution(1, distance: 10, muzzleVelocity: 20, launcher: Fixture.launcher(round: "r"),
                                               roundID: "r", downrange: DownrangeLog(), player: "x", hole: 1)
            guard case let .held(s, g) = GroupGate.gate(blocked, holds: holds) else { return XCTFail("a hold unlocked a block") }
            XCTAssertEqual(s, reasons)
            XCTAssertEqual(g, holds)
        }
    }

    /// Random member messages, including spoofed commander and match-host messages sent from a
    /// member's phone, never turn held firing data into shown.
    func testMemberMessagesNeverUnlock() throws {
        for scenario in 0..<3 {
            let w = World()
            let red = w.addSquad("Red", members: ["Ana", "Ben"])
            let blue = w.addSquad("Blue", members: ["Cy"])
            w.actMatch { $0.start(now: w.now) }
            let hole = Fixture.course().holes[0]
            w.position(red.members[0], at: Fixture.origin, commander: red.commander)
            w.position(red.members[1], at: Geo.offset(Fixture.origin, east: -12, north: -2), commander: red.commander)
            w.position(blue.members[0], at: Geo.offset(Fixture.origin, east: 12, north: -2), commander: blue.commander)
            try w.act(red.id) { try $0.startNextHole() }
            w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: hole.flag.position))), to: red.commander)
            w.act(red.id) { $0.designatedSpotter = red.members[1].id; return [] }
            switch scenario {
            case 0: break                                                       // downrange not confirmed
            case 1: try w.act(red.id) { try $0.confirmDownrange() }             // confirmed, then check fire
                    w.actMatch { $0.raiseCheckFire(now: w.now) }
            default: try w.act(blue.id) { try $0.startNextHole() }              // blue is held by the turn
                     w.send(blue.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: hole.flag.position))), to: blue.commander)
                     try w.act(blue.id) { try $0.confirmDownrange() }
            }
            let target = scenario == 2 ? blue : red
            XCTAssertFalse(w.gate(target.id)?.isShown ?? false)

            var rng = SeededGenerator(seed: UInt64(42 + scenario))
            let senders = red.members + blue.members
            for _ in 0..<400 {
                let who = senders[Int.random(in: 0..<senders.count, using: &rng)]
                let commander = red.members.contains(who) ? red.commander : blue.commander
                let n = Int.random(in: 1...2, using: &rng), mission = Int.random(in: 1...2, using: &rng)
                let lockFrom = Geo.offset(Fixture.origin, east: Double.random(in: -20...20, using: &rng), north: Double.random(in: -5...35, using: &rng))
                let fake = MatchView(revision: 9_999, hole: 1, order: [target.id], current: target.id, scores: [:], holds: [],
                                     activeCheckFires: [], seenCheckFires: Set(w.match!.seenCheckFires), finished: false)
                let messages: [GroupMessage] = [
                    .position(MemberPosition(member: who.id, at: lockFrom, accuracy: 3, time: w.now)),
                    .lock(LockReport(hole: n, purpose: [.initial, .nextMission, .verify, .observation][Int.random(in: 0..<4, using: &rng)],
                                     lock: Fixture.lock(at: lockFrom, on: hole.flag.position))),
                    .fired(hole: n, mission: mission),
                    .spot(SpotReport(hole: n, mission: mission, round: Int.random(in: 1...4, using: &rng),
                                     call: RangeCall.allCases[Int.random(in: 0..<3, using: &rng)], lateral: Double.random(in: -2...2, using: &rng))),
                    .join(JoinRequest(member: who.id, name: who.name, courseID: "test", courseVersion: 3)),
                    // Spoofs: a member pretending to be the match host or a commander.
                    .matchView(fake),
                    .squadStatus(SquadStatus(squad: target.id, revision: 9_999, hole: 1, phase: .finished, firingPoint: 0, score: 1)),
                    .register(SquadEntry(squad: target.id, name: "x", members: [])),
                    .ack(Ack(id: UUID(), applied: true, reason: nil))
                ]
                w.send(who, messages[Int.random(in: 0..<messages.count, using: &rng)], to: commander)
                // A member also tries the match host directly.
                w.send(who, .matchView(fake), to: w.matchDevice)
                XCTAssertFalse(w.gate(target.id)?.isShown ?? false, "scenario \(scenario): member input unlocked firing data")
                XCTAssertEqual(w.squads[target.id]!.downrange.isConfirmed(player: target.id == red.id ? "Red" : "Blue", hole: 1),
                               scenario != 0 && scenario != 1, "members can't confirm downrange")
            }
        }
    }

    func testCheckFireRevokesDownrangeAndNeedsReconfirmation() throws {
        let w = World()
        let red = w.addSquad("Red", members: ["Ana", "Ben"])
        w.actMatch { $0.start(now: w.now) }
        let hole = Fixture.course().holes[0]
        w.position(red.members[0], at: Fixture.origin, commander: red.commander)
        w.position(red.members[1], at: Geo.offset(Fixture.origin, east: -12, north: -2), commander: red.commander)
        try w.act(red.id) { try $0.startNextHole() }
        w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: hole.flag.position))), to: red.commander)
        try w.act(red.id) { try $0.confirmDownrange() }
        XCTAssertTrue(w.gate(red.id)!.isShown)

        // Ben calls check fire from his phone.
        let cf = CheckFire(by: red.members[1].device)
        w.send(red.members[1], .checkFire(cf), to: red.commander)
        XCTAssertFalse(w.squads[red.id]!.downrange.isConfirmed(player: "Red", hole: 1))
        XCTAssertEqual(w.match!.activeCheckFires.map(\.id), [cf.id])
        XCTAssertFalse(w.gate(red.id)!.isShown)

        // The match host withdraws it: still held until the commander confirms again.
        w.actMatch { $0.withdrawCheckFire(cf.id, now: w.now) }
        XCTAssertTrue(w.squads[red.id]!.localCheckFires.isEmpty)
        guard case let .held(safety, group)? = w.gate(red.id) else { return XCTFail() }
        XCTAssertEqual(safety, [.downrangeNotConfirmed])
        XCTAssertEqual(group, [])
        try w.act(red.id) { try $0.confirmDownrange() }
        XCTAssertTrue(w.gate(red.id)!.isShown)
    }

    func testCheckFireHoldsTheSquadBeforeTheMatchHostAnswers() throws {
        let w = World()
        let red = w.addSquad("Red", members: ["Ana"])
        w.net.cutLink(red.commander, w.matchDevice)
        w.send(red.members[0], .checkFire(CheckFire(by: red.members[0].device)), to: red.commander)
        XCTAssertTrue(w.squads[red.id]!.holds(now: w.now).contains(.checkFire(by: red.members[0].device)))
    }

    // MARK: Locks and spots

    func testLockIsRecomputedWithTheCourseFlagsPoleHeight() throws {
        let w = World(withMatch: false)
        let red = w.addSquad("Red", members: ["Ana"])
        try w.act(red.id) { try $0.startNextHole() }
        // The phone thinks the pole is 12 ft and dialled to a range that matches 30 m on that pole.
        let tall = ReticleRange(focalPixels: 3000, poleHeight: 3.658)
        let px = ReticleRange(focalPixels: 3000, poleHeight: Fixture.poleHeight).linePixels(range: 30)
        let claimed = tall.range(linePixels: px)!
        var lock = Fixture.lock(from: Fixture.origin, range: claimed, bearing: 0, poleHeight: 3.658)
        lock.reticle = tall
        w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: lock)), to: red.commander)
        XCTAssertEqual(w.squads[red.id]!.hole!.mission!.lockedRange, 30, accuracy: 0.01)
        XCTAssertGreaterThan(claimed, 40)
    }

    func testLockOffTheFlagIsRefusedWithReasons() throws {
        let w = World(withMatch: false)
        let red = w.addSquad("Red", members: ["Ana"])
        try w.act(red.id) { try $0.startNextHole() }
        let lock = Fixture.lock(from: Fixture.origin, range: 30, bearing: 60)   // the flag is due north
        w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: lock)), to: red.commander)
        XCTAssertEqual(w.squads[red.id]!.hole!.phase, .setup)
        let acks = w.memberInbox[red.members[0].device]!.compactMap { if case let .ack(a) = $0 { return a }; return nil }
        XCTAssertEqual(acks.last?.applied, false)
        XCTAssertTrue(acks.last?.reason?.contains("published flag") == true, acks.last?.reason ?? "")
    }

    func testWrongRoundSpotIsRefused() throws {
        let w = World(withMatch: false)
        let red = w.addSquad("Red", members: ["Ana"])
        try w.act(red.id) { try $0.startNextHole() }
        let flag = Fixture.course().holes[0].flag.position
        w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: flag))), to: red.commander)
        // No round fired yet.
        w.send(red.members[0], .spot(SpotReport(hole: 1, mission: 1, round: 1, call: .short, lateral: 0)), to: red.commander)
        XCTAssertEqual(w.squads[red.id]!.hole!.roundsFired, 0)
        w.send(red.members[0], .fired(hole: 1, mission: 1), to: red.commander)
        w.send(red.members[0], .spot(SpotReport(hole: 1, mission: 1, round: 2, call: .short, lateral: 0)), to: red.commander)
        XCTAssertTrue(w.squads[red.id]!.reports.isEmpty)
        w.send(red.members[0], .spot(SpotReport(hole: 1, mission: 1, round: 1, call: .short, lateral: 0.5)), to: red.commander)
        XCTAssertEqual(w.squads[red.id]!.reports.count, 1)
        XCTAssertThrowsError(try w.act(red.id) { try $0.ceaseFire() })   // a round is still in flight
    }

    func testAmendReplaysTheHole() throws {
        let w = World(withMatch: false)
        let red = w.addSquad("Red", members: ["Ana"])
        try w.act(red.id) { try $0.startNextHole() }
        let flag = Fixture.course().holes[0].flag.position
        w.send(red.members[0], .lock(LockReport(hole: 1, purpose: .initial, lock: Fixture.lock(at: Fixture.origin, on: flag))), to: red.commander)
        for call in [RangeCall.short, .short] {
            w.send(red.members[0], .fired(hole: 1, mission: 1), to: red.commander)
            try w.act(red.id) { try $0.commit(call: call, lateral: 0) }
        }
        XCTAssertEqual(w.squads[red.id]!.hole!.mission!.fireControl.rangeAdjustment, 4, accuracy: 1e-9)
        try w.act(red.id) { try $0.amend(round: 2, with: Spot(call: .over, lateral: 0)) }
        // Short then over: bracketed, so the second step halves to 1 and drops.
        XCTAssertEqual(w.squads[red.id]!.hole!.mission!.fireControl.rangeAdjustment, 1, accuracy: 1e-9)
        XCTAssertEqual(w.squads[red.id]!.hole!.roundsFired, 2)
    }

    func testJoinNeedsTheSameCourseAndApproval() {
        let w = World(withMatch: false)
        let red = w.addSquad("Red", members: [])
        w.act(red.id) { $0.autoApprove = false; return [] }
        let phone = w.net.endpoint()
        var inbox: [GroupMessage] = []
        phone.onReceive = { inbox.append($0.body) }
        phone.send(.join(JoinRequest(member: MemberID(), name: "Old", courseID: "test", courseVersion: 2)), to: red.commander)
        w.net.deliver()
        XCTAssertTrue(inbox.contains { if case .refused = $0 { return true }; return false })
        phone.send(.join(JoinRequest(member: MemberID(), name: "Eve", courseID: "test", courseVersion: 3)), to: red.commander)
        w.net.deliver()
        XCTAssertEqual(w.squads[red.id]!.squad.members.count, 0)
        XCTAssertNotNil(w.squads[red.id]!.pendingJoins[phone.device])
        w.act(red.id) { $0.approve(phone.device) }
        XCTAssertEqual(w.squads[red.id]!.squad.members.map(\.name), ["Eve"])
        // An unknown device can't act.
        let stranger = w.net.endpoint()
        stranger.send(.fired(hole: 1, mission: 1), to: red.commander)
        w.net.deliver()
        XCTAssertTrue(w.squads[red.id]!.log.last?.contains("unknown device") == true)
    }

    func testHostStateIsCodable() throws {
        let w = World()
        let red = w.addSquad("Red", members: ["Ana"])
        let h = w.squads[red.id]!
        XCTAssertEqual(try JSONDecoder().decode(SquadHost.self, from: JSONEncoder().encode(h)), h)
        let m = w.match!
        XCTAssertEqual(try JSONDecoder().decode(MatchHost.self, from: JSONEncoder().encode(m)), m)
    }
}
