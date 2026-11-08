import Foundation
import XCTest
import CoreGeo
import SafetyKit
import RangingKit
import BallisticsKit
import CourseKit
import RoundKit
@testable import GroupKit

/// The rules in docs/GROUP_PLAY.md, Safety, pinned as tests.
final class SafetyPropertyTests: XCTestCase {

    // MARK: Nothing that clears or fires crosses the wire

    func testClearedAndSolutionsCantBeEncoded() {
        XCTAssertFalse((Cleared<Int>.self as Any.Type) is Decodable.Type)
        XCTAssertFalse((Cleared<Int>.self as Any.Type) is Encodable.Type)
        XCTAssertFalse((Solution.self as Any.Type) is Encodable.Type)
    }

    /// One sample of every message body. The switch makes a new case fail to compile until it's
    /// added here, so the scan below always covers the whole protocol.
    static func samples() -> [GroupMessage.Body] {
        let t = Date(timeIntervalSince1970: 1_800_000_000.25)   // the wire keeps milliseconds
        let squad = Squad(name: "Red", members: [Member(name: "Ana", device: UUID(), role: .gunner)])
        var lock = reticleLock((40, 10, 0.2), from: .zero, poleHeight: 2.438)
        lock.date = t
        let state = MatchState(revision: 3, courseID: "c", courseVersion: 1, courseHash: "h",
                               squads: [SquadEntry(id: squad.id, name: "Red")], started: true,
                               turn: Turn(hole: 1, squad: squad.id), scores: [squad.id: [1: 4.5]],
                               holds: [.checkFire(by: "Ana"), .walkingOut(squad.id), .memberInFan(MemberID(), name: "Ben"),
                                       .positionUnknown(MemberID(), name: "Cy"), .matchHostLost, .notYourTurn, .noMatch],
                               knownCheckFires: [UUID()])
        let all: [GroupMessage.Body] = [
            .hello(Hello(name: "Ana", device: UUID(), joinCode: "RED")),
            .bye,
            .position(MemberPosition(at: origin, accuracy: 3, heading: 12, time: t)),
            .lock(LockReport(purpose: .initial, lock: lock)),
            .spot(SpotReport(hole: 1, mission: 1, round: 1, call: .over, lateral: -0.4, vantage: origin)),
            .fired(FiredReport(hole: 1, mission: 1, round: 1)),
            .orderAck(OrderAck(order: UUID(), response: .done)),
            .order(Order(kind: .moveTo, text: "Left flank, by the shed", at: origin, to: [MemberID()], time: t)),
            .checkFire(CheckFire(by: "Ana")),
            .welcome(Welcome(member: MemberID(), squad: squad)),
            .observing(squad),
            .course(testCourse()),
            .refused("no"),
            .squadStatus(SquadStatus(revision: 1, squad: squad, hole: 1, phase: .firing, walkingOut: false, missions: 1,
                                     rounds: [RoundSummary(number: 1, mission: 1, call: .short, lateral: 0.2, addDrop: 4,
                                                           rightLeft: -0.2, lost: false)],
                                     roundInFlight: 2, total: 3, toPar: -1, yourTurn: true, holds: [.notYourTurn])),
            .spotRequest(SpotRequest(hole: 1, mission: 1, round: 2)),
            .lockReceipt(LockReceipt(lock: UUID(), status: .refused, reasons: ["far"])),
            .joinMatch(JoinMatch(squad: squad.id, name: "Red", joinCode: "M", courseID: "c", courseVersion: 1, courseHash: "h")),
            .squadReport(SquadReport(squad: squad.id, revision: 2, members: squad.members, hole: 1, phase: .firing,
                                     walkingOut: false, fan: Fan(origin: origin, bearing: 10), scores: [1: 4.5])),
            .positions(squad: squad.id, [MemberPosition(member: MemberID(), at: origin, accuracy: 2, time: t)]),
            .matchState(state)
        ]
        for body in all {
            switch body {   // exhaustive on purpose
            case .hello, .bye, .position, .lock, .spot, .fired, .orderAck, .order, .checkFire, .welcome, .observing, .course, .refused, .squadStatus,
                 .spotRequest, .lockReceipt, .joinMatch, .squadReport, .positions, .matchState: break
            }
        }
        return all
    }

    func testNoMessageCarriesFiringData() throws {
        let forbidden = ["charge", "elevation", "aimoffset", "timeofflight", "solution", "cleared", "velocity", "apex"]
        for body in Self.samples() {
            let frame = try GroupWire.encode(GroupMessage(seq: 1, body: body))
            let json = String(decoding: frame.dropFirst(4), as: UTF8.self).lowercased()
            for word in forbidden {
                XCTAssertFalse(json.contains("\"\(word)"), "\(body) carries \(word): \(json)")
            }
            var reader = GroupWire.FrameReader()
            XCTAssertEqual(try reader.append(frame), [GroupMessage(seq: 1, body: body)], "round trip")
        }
    }

    // MARK: Wire

    func testFramesSplitAndJoinedAcrossReads() throws {
        let bodies = Self.samples()
        var stream = Data()
        for (i, b) in bodies.enumerated() { stream.append(try GroupWire.encode(GroupMessage(seq: i, body: b))) }
        var reader = GroupWire.FrameReader()
        var got: [GroupMessage] = []
        var i = stream.startIndex
        var chunk = 1
        while i < stream.endIndex {
            let end = min(stream.endIndex, i + chunk)
            got += try reader.append(stream[i..<end])
            i = end
            chunk = chunk % 97 + 7
        }
        XCTAssertEqual(got.map(\.body), bodies)
    }

    func testOversizeAndGarbageFramesAreRefused() {
        var reader = GroupWire.FrameReader()
        var huge = UInt32(GroupWire.maxFrameBytes + 1).bigEndian
        XCTAssertThrowsError(try reader.append(Data(bytes: &huge, count: 4)))
        var junk = UInt32(5).bigEndian
        var frame = Data(bytes: &junk, count: 4)
        frame.append(Data("hello".utf8))
        XCTAssertThrowsError(try reader.append(frame))
    }

    func testOtherProtocolVersionsAreRefused() {
        var host = SquadHost(squad: Squad(name: "Red"), course: testCourse(), practice: true, joinCode: "RED")
        let out = host.handle(GroupMessage(protocolVersion: GroupProtocol.version + 1, seq: 1,
                                           body: .hello(Hello(name: "Ana", device: UUID(), joinCode: "RED"))),
                              from: PeerID("p"), now: Date())
        guard case .refused = out.first?.body else { return XCTFail("\(out)") }
        XCTAssertTrue(host.round.squad.members.isEmpty)
    }

    // MARK: Holds only add

    func testGateNeverOpensWhatSafetyKitBlocked() {
        let launcher = conformingLauncher(round: "r")
        let block = Safety.clearSolution(7, distance: 40, muzzleVelocity: 20, launcher: launcher, roundID: "r",
                                         downrange: DownrangeLog(), player: "Red", hole: 1)
        XCTAssertEqual(GroupGate.display(block, holds: []).safetyReasons, [.downrangeNotConfirmed])
        var log = DownrangeLog()
        log.confirm(player: "Red", hole: 1)
        let ok = Safety.clearSolution(7, distance: 40, muzzleVelocity: 20, launcher: launcher, roundID: "r",
                                      downrange: log, player: "Red", hole: 1)
        XCTAssertTrue(GroupGate.display(ok, holds: []).isShown)
        for hold in [Hold.noMatch, .notYourTurn, .matchHostLost, .checkFire(by: "x")] {
            XCTAssertFalse(GroupGate.display(ok, holds: [hold]).isShown, "\(hold)")
        }
    }

    /// Random traffic from phones (joined or not, well-formed or junk) never shows firing data
    /// that was held, never confirms downrange, and never lifts a hold.
    func testMessageFuzzCantUnlock() {
        var g = SeededGenerator(seed: 0xF022)
        for scenario in 0..<4 {
            let f = Field()
            f.addSquad("Red")
            f.addSquad("Blue")
            let ana = f.addPhone("Ana", squad: "Red", at: Ground(0, -2))
            let mal = f.addPhone("Mal", squad: "Red", at: Ground(1, -3))
            f.addPhone("Dee", squad: "Blue", at: Ground(4, -4))
            f.tick()
            f.matchAction { m, now in m.start(now: now) }
            f.command("Red") { $0.startNextHole(now: $1) }
            let hole = f.hosts["Red"]!.round.currentHole!
            var range = PracticeRange(pole: ground(hole.flag.position), poleHeight: 2.438, wind: .calm, seed: 9)
            let lock = LockReport(purpose: .initial, lock: reticleLock(range.lock(from: .zero), from: .zero, poleHeight: 2.438))
            f.send(ana, .lock(lock))
            f.command("Red") { $0.useLock(lock.id, now: $1) }
            // Each scenario starts held a different way.
            switch scenario {
            case 0: break                                                     // downrange not confirmed
            case 1: f.command("Red") { $0.confirmDownrange(now: $1) }
                    f.command("Red") { $0.ceaseFire(now: $1) }                 // walking out
            case 2: f.command("Red") { $0.confirmDownrange(now: $1) }
                    f.matchAction { m, now in m.callCheckFire(by: "Host", now: now) }
            default: f.command("Red") { $0.confirmDownrange(now: $1) }
                    f.net.down.insert(f.matchPeer)
                    f.tick(SquadHost.matchHostTimeout + 1)                     // match host lost
            }
            f.tick(0)
            let heldBefore = f.holds("Red")
            let confirmedBefore = f.hosts["Red"]!.isDownrangeConfirmed()
            XCTAssertFalse(isShown(f), "scenario \(scenario) starts blocked")

            // Not the match host itself: its link is authenticated (the match code keys its TLS in G4).
            let peers = [ana.peer, mal.peer, PeerID("stranger"), PeerID("fake-match")]
            for _ in 0..<600 {
                let from = peers[Int.random(in: 0..<peers.count, using: &g)]
                if Int.random(in: 0..<10, using: &g) == 0 {
                    var bytes = Data((0..<Int.random(in: 1..<40, using: &g)).map { _ in UInt8.random(in: 0...255, using: &g) })
                    if Bool.random(using: &g) { bytes.replaceSubrange(0..<min(4, bytes.count), with: [0, 0, 0, 20]) }
                    f.net.sendRaw(from: from, to: Field.ipad("Red"), bytes)
                } else {
                    var body = randomBody(&g, f: f)
                    // A phone pretending to be the match host, with every hold lifted.
                    if case var .matchState(s) = body { s.holds = []; s.turn = Turn(hole: 1, squad: f.hosts["Red"]!.squadID); body = .matchState(s) }
                    f.net.send(from: from, [Outgoing(to: Field.ipad("Red"), body)])
                }
                f.net.run()
                XCTAssertFalse(isShown(f), "scenario \(scenario): a message unlocked firing data")
                XCTAssertTrue(heldBefore.isSubset(of: f.holds("Red")), "scenario \(scenario): a hold was lifted")
                if !confirmedBefore { XCTAssertFalse(f.hosts["Red"]!.isDownrangeConfirmed()) }
            }
        }
    }

    private func isShown(_ f: Field) -> Bool {
        let host = f.hosts["Red"]!
        guard let h = host.round.hole, let m = h.mission else { return false }
        // The gate doesn't depend on the solution's value, so skip the solver: a fixed charge velocity.
        let verdict = Safety.clearSolution(m.number, distance: m.fireControl.aimRange, muzzleVelocity: 20,
                                           launcher: conformingLauncher(round: "r"), roundID: "r",
                                           downrange: host.round.downrange, player: host.player, hole: h.holeNumber)
        return host.firingDisplay(verdict, now: f.now).isShown
    }

    private func randomBody(_ g: inout SeededGenerator, f: Field) -> GroupMessage.Body {
        var pick = Self.samples()
        // Make some of them plausible for the hole in play.
        pick.append(.fired(FiredReport(hole: 1, mission: 1, round: 1)))
        pick.append(.spot(SpotReport(hole: 1, mission: 1, round: 1, call: .rangeCorrect, lateral: 0)))
        pick.append(.hello(Hello(name: "Mal", device: UUID(), joinCode: "RED")))
        pick.append(.position(MemberPosition(at: origin, accuracy: 1, time: f.now)))
        return pick[Int.random(in: 0..<pick.count, using: &g)]
    }
}
