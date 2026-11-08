import Foundation
import XCTest
import CoreGeo
import CourseKit
import FieldKit
import GroupKit
@testable import TheaterKit

final class TheaterHostTests: XCTestCase {
    private var root: URL!
    private var theater: TheaterHost!
    private let phone = PeerID("phone")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("theater-\(UUID().uuidString)")
        theater = TheaterHost(name: "M6Pro", joinCode: "THTR23", store: FieldStore(root: root))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func send(_ body: GroupMessage.Body, from peer: PeerID? = nil) -> [Outgoing] {
        theater.handle(GroupMessage(seq: 1, body: body), from: peer ?? phone, now: now)
    }

    private func receipt(_ out: [Outgoing]) -> Receipt? {
        for o in out { if case let .receipt(r) = o.body { return r } }
        return nil
    }

    private func join() {
        let out = send(.hello(Hello(name: "Ana", device: UUID(), joinCode: "thtr-23", role: .contributor)))
        XCTAssertEqual(receipt(out)?.status, .stored, "\(out)")
    }

    private func course(_ id: String = "barn", version: Int = 1) -> Course {
        let o = GeoPoint(latitude: 42.36, longitude: -71.06)
        let box = GeoPolygon([Geo.offset(o, east: -150, north: -150), Geo.offset(o, east: 150, north: -150),
                              Geo.offset(o, east: 150, north: 150), Geo.offset(o, east: -150, north: 150)])
        let hole = Hole(number: 1, name: "One", par: 4, firingPoints: [o],
                        flag: Flag(position: Geo.offset(o, east: 0, north: 30), poleHeightM: 2.438, leanDeg: 0.2))
        return Course(format: 1, id: id, name: "The Barn", version: version, boundary: box, holes: [hole])
    }

    func testOnlyContributorsWithTheCodeGetIn() {
        guard case .refused? = send(.hello(Hello(name: "Eve", device: UUID(), joinCode: "WRONG1", role: .contributor))).first?.body else {
            return XCTFail("wrong code accepted")
        }
        guard case .refused? = send(.hello(Hello(name: "Ben", device: UUID(), joinCode: "THTR23"))).first?.body else {
            return XCTFail("a squad member's hello should be pointed elsewhere")
        }
        XCTAssertTrue(send(.fieldNote(FieldNote(author: "Eve", time: now, text: "hi"))).isEmpty, "not joined: ignored")
        join()
        XCTAssertEqual(theater.contributors[phone]?.name, "Ana")
    }

    func testAFieldFromAPhoneIsRegistered() throws {
        join()
        let r = receipt(send(.fieldSubmission(FieldSubmission(author: "spoofed", time: now, course: course(), yaml: "id: barn\n"))))
        XCTAssertEqual(r?.status, .stored)
        let f = try XCTUnwrap(theater.store.field("barn"))
        XCTAssertEqual(f.field.source, "From Ana", "the author is who joined, not what the message says")
        XCTAssertEqual(receipt(send(.fieldSubmission(FieldSubmission(author: "Ana", time: now, course: course(version: 0)))))?.status,
                       .refused, "older than what's registered")
    }

    func testABrokenFieldIsRefusedWithReasons() {
        join()
        var c = course()
        c.holes = []
        let r = receipt(send(.fieldSubmission(FieldSubmission(author: "Ana", time: now, course: c))))
        XCTAssertEqual(r?.status, .refused)
        XCTAssertFalse(r?.detail.isEmpty ?? true)
        XCTAssertNil(theater.store.field("barn"))
    }

    func testNotesAreSavedWithTheirPhoto() throws {
        join()
        let photo = Data(repeating: 7, count: 1000)
        let n = FieldNote(author: "x", time: now, courseID: "barn", at: GeoPoint(latitude: 42.36, longitude: -71.06),
                          accuracy: 4, text: "Wasp nest in the hedge", photo: photo)
        XCTAssertEqual(receipt(send(.fieldNote(n)))?.status, .stored)
        let saved = TheaterHost.notes(in: theater.store, courseID: "barn")
        XCTAssertEqual(saved.map(\.note.text), ["Wasp nest in the hedge"])
        XCTAssertEqual(saved.first?.note.author, "Ana")
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(saved.first?.photo)), photo)
        // A note with no field, or a field ID that isn't a plain name, goes to _unfiled.
        _ = send(.fieldNote(FieldNote(author: "x", time: now, courseID: "../../etc", text: "sneaky")))
        XCTAssertEqual(TheaterHost.notes(in: theater.store, courseID: nil).map(\.note.text), ["sneaky"])
    }

    /// A capture's photo in three chunks lands whole in the field's captures folder.
    func testAFileArrivesInChunks() throws {
        join()
        let data = Data((0..<(FileOffer.chunkBytes * 2 + 1000)).map { UInt8($0 % 251) })
        let group = UUID()
        let offer = FileOffer(kind: .capture, group: group, name: "shot-1.jpg", size: data.count, sha256: data.sha256Hex, courseID: "barn")
        XCTAssertTrue(send(.fileOffer(offer)).isEmpty)
        for (i, start) in stride(from: 0, to: data.count, by: FileOffer.chunkBytes).enumerated() {
            let piece = data.subdata(in: start..<min(data.count, start + FileOffer.chunkBytes))
            XCTAssertTrue(send(.fileChunk(FileChunk(file: offer.id, index: i, data: piece))).isEmpty)
        }
        XCTAssertEqual(receipt(send(.fileDone(offer.id)))?.status, .stored)
        let dest = theater.store.capturesDirectory("barn").appendingPathComponent("\(group.uuidString)/shot-1.jpg")
        XCTAssertEqual(try Data(contentsOf: dest), data)
    }

    func testBadFilesAreRefusedAndCleanedUp() throws {
        join()
        let data = Data(repeating: 1, count: 5000)
        // A wrong checksum.
        var offer = FileOffer(kind: .capture, group: UUID(), name: "a.jpg", size: data.count, sha256: "00", courseID: "barn")
        _ = send(.fileOffer(offer))
        _ = send(.fileChunk(FileChunk(file: offer.id, index: 0, data: data)))
        XCTAssertEqual(receipt(send(.fileDone(offer.id)))?.status, .refused)
        let incoming = root.appendingPathComponent(".incoming")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: incoming.path), [], "the partial file is removed")
        // A name that tries to leave its folder.
        offer = FileOffer(kind: .capture, group: UUID(), name: "../../evil.sh", size: 10, sha256: "x", courseID: "barn")
        XCTAssertEqual(receipt(send(.fileOffer(offer)))?.status, .refused)
        // Chunks out of order.
        offer = FileOffer(kind: .capture, group: UUID(), name: "b.jpg", size: data.count, sha256: data.sha256Hex, courseID: "barn")
        _ = send(.fileOffer(offer))
        XCTAssertEqual(receipt(send(.fileChunk(FileChunk(file: offer.id, index: 1, data: data))))?.status, .refused)
        // Another phone can't add to someone else's upload.
        offer = FileOffer(kind: .capture, group: UUID(), name: "c.jpg", size: data.count, sha256: data.sha256Hex, courseID: "barn")
        _ = send(.fileOffer(offer))
        XCTAssertTrue(send(.fileChunk(FileChunk(file: offer.id, index: 0, data: data)), from: PeerID("stranger")).isEmpty)
        // And a dropped link drops its uploads.
        theater.peerClosed(phone)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: incoming.path), [])
    }

    func testNotesPassedOnFromASquad() {
        let r = theater.recordNote(FieldNote(author: "Ben", time: now, courseID: "barn", text: "Pole leaning"), fromSquad: "Red")
        XCTAssertEqual(r.status, .stored)
        XCTAssertEqual(TheaterHost.notes(in: theater.store, courseID: "barn").first?.note.author, "Ben (Red)")
    }
}
