import Foundation
import XCTest
import CoreGeo
@testable import GroupKit

/// A mission with no golf in it: a rally point the commander sets. It adds no holds.
struct RallyMission: Mission {
    static let id = "test.rally"
    static let version = 1
    var rally: GeoPoint?
    /// A mission that tries to lift holds: it returns none, whatever is going on.
    func holds(core: CoreView, now: Date) -> Set<Hold> { [] }
    mutating func handle(_ body: GroupMessage.Body, from member: MemberID, peer: PeerID,
                         core: CoreView, now: Date) -> MissionStep? { nil }
    mutating func checkFireRaised(core: CoreView) {}
    func role(forNewMemberOf squad: Squad) -> MemberRole { .member }
    func observerWelcome(core: CoreView) -> [GroupMessage.Body] { [] }
    func fill(_ status: inout SquadStatus, core: CoreView, now: Date) {}
}

/// The squad core on its own (docs/SQUAD_CORE.md, C1): join, positions, orders, check fire.
final class SquadCoreTests: XCTestCase {
    func testTheCoreRunsASquadWithoutGolf() throws {
        let net = LoopbackNetwork()
        let ipad = PeerID("ipad"), phone = PeerID("phone"), theater = PeerID("theater")
        var host = SquadCore(squad: Squad(name: "Blue"), mission: RallyMission(), joinCode: "BLUE")
        var got: [GroupMessage.Body] = []
        var watched: [GroupMessage.Body] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        net.add(ipad) { m, from in host.handle(m, from: from, now: now) }
        net.add(phone) { m, _ in got.append(m.body); return [] }
        net.add(theater) { m, _ in watched.append(m.body); return [] }

        net.send(from: phone, [Outgoing(to: ipad, .hello(Hello(name: "Ana", device: UUID(), joinCode: "BLUE")))])
        net.send(from: theater, [Outgoing(to: ipad, .hello(Hello(name: "Theater", device: UUID(), joinCode: "BLUE", role: .observer)))])
        _ = net.run()
        XCTAssertEqual(host.squad.members.map(\.name), ["Ana"])
        XCTAssertEqual(host.squad.members.first?.role, .member, "the mission picks the role")
        guard case .welcome = got.first else { return XCTFail("\(got)") }
        guard case .observing = watched.first else { return XCTFail("\(watched)") }

        // A position goes to observers; an order reaches the member.
        net.send(from: phone, [Outgoing(to: ipad, .position(MemberPosition(at: GeoPoint(latitude: 42, longitude: -71), accuracy: 3, time: now)))])
        _ = net.run()
        XCTAssertNotNil(host.positions[host.squad.members[0].id])
        XCTAssertTrue(watched.contains { if case .positions = $0 { return true } else { return false } })
        net.send(from: ipad, host.sendOrder(.moveTo, text: "To the oak", now: now))
        _ = net.run()
        XCTAssertTrue(got.contains { if case .order = $0 { return true } else { return false } })

        // Check fire from the phone holds the squad, even though the mission returns no holds.
        net.send(from: phone, [Outgoing(to: ipad, .checkFire(CheckFire(by: "Ana")))])
        _ = net.run()
        XCTAssertEqual(host.holds(now: now), [.checkFire(by: "Ana")])
        guard case let .squadStatus(s)? = got.last else { return XCTFail("\(got)") }
        XCTAssertEqual(s.holds, [.checkFire(by: "Ana")])
        XCTAssertNil(s.hole, "no golf in the status")
        // Only the commander lifts it.
        net.send(from: ipad, host.withdrawCheckFire(now: now))
        _ = net.run()
        XCTAssertTrue(host.holds(now: now).isEmpty)
    }

    /// Golf messages sent to a squad that isn't playing golf are ignored.
    func testMessagesForAnotherMissionAreIgnored() {
        var host = SquadCore(squad: Squad(name: "Blue"), mission: RallyMission(), joinCode: "BLUE")
        let phone = PeerID("phone")
        let now = Date()
        _ = host.handle(GroupMessage(seq: 1, body: .hello(Hello(name: "Ana", device: UUID(), joinCode: "BLUE"))), from: phone, now: now)
        let revision = host.revision
        for body in SafetyPropertyTests.samples() {
            switch body {
            case .lock, .spot, .fired, .fieldSubmission:
                XCTAssertTrue(host.handle(GroupMessage(seq: 2, body: body), from: phone, now: now).isEmpty, "\(body)")
            default: break
            }
        }
        XCTAssertEqual(host.revision, revision)
    }
}
