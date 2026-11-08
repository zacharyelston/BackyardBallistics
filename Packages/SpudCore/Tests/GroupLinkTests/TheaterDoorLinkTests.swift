import Foundation
import Network
import XCTest
import CoreGeo
import FieldKit
import GroupKit
import TheaterKit
@testable import GroupLink

/// The Theater's door over real sockets on this Mac, wired the way SpudTheater wires it: a
/// GroupHost feeding a TheaterHost, and a phone's GroupClient joining as a contributor.
final class TheaterDoorLinkTests: XCTestCase {
    let queue = DispatchQueue(label: "theater-door-test")

    func testAPhoneSendsANoteAndAFileToTheTheater() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("door-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let code = JoinCode.make()
        var theater = TheaterHost(name: "Mac", joinCode: code, store: FieldStore(root: root))
        let host = try GroupHost(name: "Mac", joinCode: code, txt: ["role": "theater"], advertise: false, queue: queue)
        host.onMessage = { [unowned host] m, peer in host.send(theater.handle(m, from: peer, now: Date())) }
        host.onPeerClosed = { peer in theater.peerClosed(peer) }
        let ready = expectation(description: "listening")
        host.onReady = { _ in ready.fulfill() }
        host.start()
        wait(for: [ready], timeout: 5)
        defer { host.stop() }

        let phone = GroupClient(squadName: "Mac", joinCode: code,
                                hello: Hello(name: "Ana", device: UUID(), joinCode: code, role: .contributor), queue: queue)
        phone.fixedEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: host.port!)!)
        var receipts: [Receipt] = []
        let joined = expectation(description: "joined")
        let noteSaved = expectation(description: "note saved")
        let fileSaved = expectation(description: "file saved")
        let note = FieldNote(author: "spoofed", time: Date(), courseID: "barn",
                             at: GeoPoint(latitude: 42.36, longitude: -71.06), accuracy: 4, text: "Gate is locked")
        let data = Data((0..<(FileOffer.chunkBytes + 1000)).map { UInt8($0 % 251) })   // two pieces
        let offer = FileOffer(kind: .capture, group: UUID(), name: "capture.json", size: data.count,
                              sha256: data.sha256Hex, courseID: "barn")
        phone.onMessage = { m in
            guard case let .receipt(r) = m.body else { return }
            receipts.append(r)
            if r.id == note.id { noteSaved.fulfill() } else if r.id == offer.id { fileSaved.fulfill() } else { joined.fulfill() }
        }
        phone.start()
        wait(for: [joined], timeout: 5)

        queue.sync {
            phone.send(.fieldNote(note))
            phone.send(.fileOffer(offer))
            phone.send(.fileChunk(FileChunk(file: offer.id, index: 0, data: data.prefix(FileOffer.chunkBytes))))
            phone.send(.fileChunk(FileChunk(file: offer.id, index: 1, data: data.suffix(from: FileOffer.chunkBytes))))
            phone.send(.fileDone(offer.id))
        }
        wait(for: [noteSaved, fileSaved], timeout: 10)
        XCTAssertTrue(receipts.allSatisfy { $0.status == .stored }, "\(receipts)")

        let saved = queue.sync { TheaterHost.notes(in: theater.store, courseID: "barn") }
        XCTAssertEqual(saved.map(\.note.text), ["Gate is locked"])
        XCTAssertEqual(saved.first?.note.author, "Ana", "the author is the connection's name")
        let file = root.appendingPathComponent("barn/captures/\(offer.group.uuidString)/capture.json")
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(queue.sync { theater.contributors.values.map(\.name) }, ["Ana"])

        queue.sync { phone.stop() }
    }
}
