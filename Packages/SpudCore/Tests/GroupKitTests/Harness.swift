import Foundation
import XCTest
import CoreGeo
import SafetyKit
import RangingKit
import BallisticsKit
import CourseKit
import RoundKit
@testable import GroupKit

let origin = GeoPoint(latitude: 42.36, longitude: -71.06)

func geo(_ g: Ground) -> GeoPoint { Geo.offset(origin, east: g.x, north: g.y) }
func ground(_ p: GeoPoint) -> Ground { let en = Geo.eastNorth(of: p, from: origin); return Ground(en.east, en.north) }

/// Two holes from one firing point at the origin.
func testCourse(version: Int = 1) -> Course {
    let holes = [
        Hole(number: 1, name: "Birdbath", par: 4, firingPoints: [origin],
             flag: Flag(position: geo(Ground(8, 40)), poleHeightM: 2.438, leanDeg: 0.2)),
        Hole(number: 2, name: "Shed", par: 4, firingPoints: [origin],
             flag: Flag(position: geo(Ground(-10, 55)), poleHeightM: 2.438, leanDeg: 0.2))
    ]
    let box = GeoPolygon([geo(Ground(-300, -300)), geo(Ground(300, -300)), geo(Ground(300, 300)), geo(Ground(-300, 300))])
    return Course(format: 1, id: "squad-test", name: "Squad test", version: version, boundary: box, holes: holes)
}

/// A launcher whose conformance checklist is complete, so SafetyKit can clear solutions in tests.
func conformingLauncher(round: String) -> LauncherConformance {
    var c = LauncherConformance(launcherID: "E1", name: "Test sling", kind: .elastic)
    c.calibratedMaxVelocity = 32
    c.inspection = Inspection(roundID: round, results: Dictionary(uniqueKeysWithValues: InspectionItem.items(for: .elastic).map { ($0, true) }))
    return c
}

/// A simulated reticle lock from `from` (local ground) on `pole`, as a phone would send it.
func reticleLock(_ simulated: (range: Double, bearing: Double, sigma: Double), from: Ground, poleHeight: Double) -> ReticleLock {
    let camera = 1.5
    let tilt = Geo.degrees(atan(camera / simulated.range))   // crosshair on the base, level ground
    return ReticleLock(reticle: ReticleRange(focalPixels: PracticeRange.stillFocalPixels, poleHeight: poleHeight, angleBelowLevel: tilt),
                       range: simulated.range, bearing: simulated.bearing, cameraHeight: camera,
                       location: geo(from), horizontalAccuracy: 3)
}

/// A member's phone: joins, reports its position, answers spot requests when told to.
final class Phone {
    let peer: PeerID
    let name: String
    let device = UUID()
    var at: Ground
    var accuracy = 3.0
    var commander: PeerID?
    var member: MemberID?
    var status: SquadStatus?
    var spotRequests: [SpotRequest] = []
    var receipts: [LockReceipt] = []
    var refusals: [String] = []
    var reportsPosition = true

    init(_ name: String, at: Ground) {
        self.peer = PeerID("phone-" + name)
        self.name = name
        self.at = at
    }

    func receive(_ m: GroupMessage, from: PeerID) -> [Outgoing] {
        switch m.body {
        case let .welcome(w): member = w.member
        case let .squadStatus(s): status = s
        case let .spotRequest(r): spotRequests.append(r)
        case let .lockReceipt(r): receipts.append(r)
        case let .refused(why): refusals.append(why)
        default: break
        }
        return []
    }
}

/// A backyard with a match host, squads and phones on the loopback network.
final class Field {
    let net = LoopbackNetwork()
    let course: Course
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    var match: MatchHost
    let matchPeer = PeerID("match")
    var hosts: [String: SquadHost] = [:]
    var phones: [String: Phone] = [:]

    init(course: Course = testCourse()) {
        self.course = course
        match = MatchHost(course: course, joinCode: "MATCH1")
        net.add(matchPeer) { [unowned self] m, from in self.match.handle(m, from: from, now: self.now) }
    }

    static func ipad(_ squad: String) -> PeerID { PeerID("ipad-" + squad) }

    @discardableResult
    func addSquad(_ name: String, course: Course? = nil, joinMatch: Bool = true) -> SquadHost {
        hosts[name] = SquadHost(squad: Squad(name: name), course: course ?? self.course, practice: true, joinCode: name.uppercased())
        net.add(Self.ipad(name)) { [unowned self] m, from in self.hosts[name]!.handle(m, from: from, now: self.now) }
        if joinMatch { command(name) { $0.connectMatch(self.matchPeer, joinCode: "MATCH1", now: $1) } }
        return hosts[name]!
    }

    @discardableResult
    func addPhone(_ name: String, squad: String, at: Ground, code: String? = nil) -> Phone {
        let p = Phone(name, at: at)
        p.commander = Self.ipad(squad)
        phones[name] = p
        net.add(p.peer) { m, from in p.receive(m, from: from) }
        send(p, .hello(Hello(name: name, device: p.device, joinCode: code ?? squad.uppercased())))
        return p
    }

    func send(_ phone: Phone, _ body: GroupMessage.Body) {
        net.send(from: phone.peer, [Outgoing(to: phone.commander!, body)])
        net.run()
    }

    /// Runs a commander's action on its iPad and delivers what it sends.
    func command(_ squad: String, _ action: (inout SquadHost, Date) -> [Outgoing]) {
        let out = action(&hosts[squad]!, now)
        net.send(from: Self.ipad(squad), out)
        net.run()
    }

    func matchAction(_ action: (inout MatchHost, Date) -> [Outgoing]) {
        let out = action(&match, now)
        net.send(from: matchPeer, out)
        net.run()
    }

    /// One second passes: phones report positions, the match host sends its heartbeat.
    func tick(_ seconds: TimeInterval = 1) {
        now += seconds
        for p in phones.values.sorted(by: { $0.name < $1.name }) where p.reportsPosition {
            send(p, .position(MemberPosition(at: geo(p.at), accuracy: p.accuracy, time: now)))
        }
        matchAction { m, now in m.tick(now: now) }
    }

    func holds(_ squad: String) -> Set<Hold> { hosts[squad]!.holds(now: now) }
}
