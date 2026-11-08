import Foundation
import Network
import XCTest
import CoreGeo
import CourseKit
import GroupKit
@testable import GroupLink

/// Real sockets on this Mac: a commander's host and a phone's connection over TLS-PSK.
final class GroupLinkTests: XCTestCase {
    let queue = DispatchQueue(label: "group-link-test")

    private func course() -> Course {
        let o = GeoPoint(latitude: 42.36, longitude: -71.06)
        let box = GeoPolygon([Geo.offset(o, east: -200, north: -200), Geo.offset(o, east: 200, north: -200),
                              Geo.offset(o, east: 200, north: 200), Geo.offset(o, east: -200, north: 200)])
        let hole = Hole(number: 1, name: "One", par: 4, firingPoints: [o],
                        flag: Flag(position: Geo.offset(o, east: 0, north: 40), poleHeightM: 2.438, leanDeg: 0.2))
        return Course(format: 1, id: "link", name: "Link", version: 1, boundary: box, holes: [hole])
    }

    /// A commander on a loopback port, wired to a SquadHost the way the iPad will be.
    private func startCommander(code: String) throws -> (GroupHost, UInt16) {
        var squad = SquadHost(squad: Squad(name: "Red"), course: course(), practice: true, joinCode: code)
        let host = try GroupHost(name: "Red", joinCode: code, advertise: false, queue: queue)
        host.onMessage = { [unowned host] m, peer in host.send(squad.handle(m, from: peer, now: Date())) }
        let ready = expectation(description: "listening")
        host.onReady = { _ in ready.fulfill() }
        host.start()
        wait(for: [ready], timeout: 5)
        return (host, host.port!)
    }

    private func local(_ port: UInt16) -> NWEndpoint { .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!) }

    func testJoinOverTLS() throws {
        let code = JoinCode.make()
        let (host, port) = try startCommander(code: code)
        defer { host.stop() }

        let phone = GroupConnection(to: local(port), joinCode: code, queue: queue)
        let welcomed = expectation(description: "welcome")
        let status = expectation(description: "status")
        status.assertForOverFulfill = false
        phone.onMessage = { m in
            switch m.body {
            case let .welcome(w):
                XCTAssertEqual(w.squad.members.map(\.name), ["Ana"])
                welcomed.fulfill()
            case .squadStatus: status.fulfill()
            default: break
            }
        }
        phone.onState = { s in if s == .ready { phone.send(.hello(Hello(name: "Ana", device: UUID(), joinCode: code))) } }
        phone.start()
        wait(for: [welcomed, status], timeout: 5)
        phone.cancel()
    }

    func testWrongCodeCantConnect() throws {
        let (host, port) = try startCommander(code: "ABC234")
        defer { host.stop() }
        let phone = GroupConnection(to: local(port), joinCode: "XYZ789", queue: queue)
        let failed = expectation(description: "refused")
        failed.assertForOverFulfill = false
        phone.onState = { s in
            if case .failed = s { failed.fulfill() }
            if s == .ready { XCTFail("connected with the wrong code") }
        }
        phone.onMessage = { m in XCTFail("got \(m.body)") }
        phone.start()
        wait(for: [failed], timeout: 5)
        phone.cancel()
    }

    func testJoinCodes() {
        let c = JoinCode.make()
        XCTAssertEqual(c.count, 6)
        XCTAssertTrue(c.allSatisfy { JoinCode.alphabet.contains($0) })
        XCTAssertEqual(JoinCode.normalized("abc-23 4"), "ABC234")
    }

    /// The iPad sleeping: its side of every link drops and its listener restarts. The phone's
    /// GroupClient finds it again and rejoins as the same member.
    func testClientRejoinsAfterTheHostDrops() throws {
        let code = JoinCode.make()
        var squad = SquadHost(squad: Squad(name: "Red"), course: course(), practice: true, joinCode: code)
        let host = try GroupHost(name: "Red", joinCode: code, advertise: false, queue: queue)
        host.onMessage = { [unowned host] m, peer in host.send(squad.handle(m, from: peer, now: Date())) }
        let ready = expectation(description: "listening")
        host.onReady = { _ in ready.fulfill() }
        host.start()
        wait(for: [ready], timeout: 5)
        host.onReady = nil   // it reports ready again after the restart
        defer { host.stop() }
        let port = host.port!

        let device = UUID()
        let client = GroupClient(squadName: "Red", joinCode: code, hello: Hello(name: "Ana", device: device, joinCode: code), queue: queue)
        client.fixedEndpoint = local(port)
        client.baseDelay = 0.2
        var welcomes: [MemberID] = []
        let first = expectation(description: "first welcome")
        let second = expectation(description: "welcome after the drop")
        var statuses: [GroupClient.Status] = []
        client.onStatus = { statuses.append($0) }
        client.onMessage = { m in
            guard case let .welcome(w) = m.body else { return }
            welcomes.append(w.member)
            if welcomes.count == 1 { first.fulfill() } else if welcomes.count == 2 { second.fulfill() }
        }
        client.start()
        wait(for: [first], timeout: 5)

        // The iPad sleeps: every connection drops, and the listener starts again on the same port.
        queue.sync {
            for c in host.connections.values { c.cancel() }
            host.restart()
        }
        wait(for: [second], timeout: 10)
        XCTAssertEqual(welcomes.count, 2)
        XCTAssertEqual(welcomes[0], welcomes[1], "rejoined as the same member")
        XCTAssertTrue(statuses.contains { if case .reconnecting = $0 { return true }; return false }, "\(statuses)")
        XCTAssertEqual(host.port, port, "the restarted listener keeps its port")
        queue.sync { client.stop() }
    }

    func testClientStopsOnAWrongCode() throws {
        let (host, port) = try startCommander(code: "ABC234")
        defer { host.stop() }
        let client = GroupClient(squadName: "Red", joinCode: "XYZ789",
                                 hello: Hello(name: "Eve", device: UUID(), joinCode: "XYZ789"), queue: queue)
        client.fixedEndpoint = local(port)
        let stopped = expectation(description: "gave up")
        client.onStatus = { s in if case .stopped = s { stopped.fulfill() } }
        client.start()
        wait(for: [stopped], timeout: 10)
    }
}
