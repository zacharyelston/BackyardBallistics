import Foundation
import XCTest
import GroupKit
@testable import GroupLink

/// A live probe of a real Theater host on the network, the way a phone links to it. Skipped unless
/// PROBE_THEATER_CODE is set (and PROBE_THEATER_NAME, else the first Theater found).
final class TheaterProbeTests: XCTestCase {
    func testProbeARealTheater() throws {
        let env = ProcessInfo.processInfo.environment
        guard let code = env["PROBE_THEATER_CODE"] else { throw XCTSkip("set PROBE_THEATER_CODE to probe a live Theater") }
        let queue = DispatchQueue(label: "probe")
        var name = env["PROBE_THEATER_NAME"]
        if name == nil {
            let found = expectation(description: "a Theater on the network")
            let b = GroupBrowser(queue: queue)
            b.onChange = { list in
                print("PROBE browse:", list.map { "\($0.name) \($0.txt)" })
                if name == nil, let t = list.first(where: { $0.txt["role"] == "theater" }) { name = t.name; found.fulfill() }
            }
            b.start()
            wait(for: [found], timeout: 10)
            b.stop()
        }
        let theater = try XCTUnwrap(name)
        print("PROBE target:", theater, "code:", code)
        let client = GroupClient(squadName: theater, joinCode: code,
                                 hello: Hello(name: "Probe", device: UUID(), joinCode: code, role: .contributor), queue: queue)
        let answered = expectation(description: "the hello answered")
        answered.assertForOverFulfill = false
        client.onStatus = { print("PROBE status:", $0) }
        client.onMessage = { m in
            print("PROBE got v\(m.protocolVersion):", m.body)
            if case .receipt = m.body { answered.fulfill() }
            if case .refused = m.body { answered.fulfill() }
        }
        queue.async { client.start() }
        wait(for: [answered], timeout: 20)
        queue.sync { client.stop() }
    }
}
