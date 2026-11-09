import Foundation
import XCTest
import CoreGeo
import CourseKit
@testable import FieldKit

final class FieldRegistryTests: XCTestCase {
    private var root: URL!
    private var store: FieldStore { FieldStore(root: root) }

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("fields-\(UUID().uuidString)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func course(_ id: String, _ name: String, version: Int, holes: Int = 2) -> Course {
        let o = GeoPoint(latitude: 42.36, longitude: -71.06)
        let box = GeoPolygon([Geo.offset(o, east: -50, north: -50), Geo.offset(o, east: 50, north: -50),
                              Geo.offset(o, east: 50, north: 50), Geo.offset(o, east: -50, north: 50)])
        let hs = (1...holes).map { n in
            Hole(number: n, name: "H\(n)", par: 4, firingPoints: [o],
                 flag: Flag(position: Geo.offset(o, east: 0, north: 20 + Double(n)), poleHeightM: 2.438, leanDeg: 0.2))
        }
        return Course(format: 1, id: id, name: name, version: version, boundary: box, holes: hs)
    }

    func testRegisterListAndUpdate() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(try store.register(course("barn", "The Barn", version: 1), source: "From squad Red", now: t0), .added)
        XCTAssertEqual(try store.register(course("elm", "Elm Street", version: 3), source: "Imported", yaml: "name: Elm\n", now: t0), .added)
        XCTAssertEqual(store.fields().map(\.field.name), ["Elm Street", "The Barn"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.courseDirectory("elm").appendingPathComponent("course.yaml").path))

        // Same version again: nothing changes.
        XCTAssertEqual(try store.register(course("barn", "The Barn", version: 1), source: "From squad Blue"), .unchanged)
        XCTAssertEqual(store.field("barn")?.field.source, "From squad Red")

        // A newer version replaces it; the old one is kept; first-registered time stays.
        let t1 = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertEqual(try store.register(course("barn", "The Barn", version: 2, holes: 3), source: "From squad Blue", now: t1), .updated(from: 1))
        let barn = try XCTUnwrap(store.field("barn"))
        XCTAssertEqual(barn.field.version, 2)
        XCTAssertEqual(barn.field.holes, 3)
        XCTAssertEqual(barn.field.registeredAt, t0)
        XCTAssertEqual(barn.field.updatedAt, t1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.courseDirectory("barn").appendingPathComponent("versions/1.json").path))

        // An older one doesn't overwrite.
        XCTAssertEqual(try store.register(course("barn", "The Barn", version: 1), source: "Old phone"), .olderIgnored(registered: 2))
        XCTAssertEqual(store.field("barn")?.field.version, 2)
    }

    func testSeenAndForget() throws {
        try store.register(course("barn", "The Barn", version: 1), source: "x")
        let seen = Date(timeIntervalSince1970: 3_000_000)
        store.markSeen("barn", at: seen)
        XCTAssertEqual(store.field("barn")?.field.lastSeen, seen)

        let moved = try store.forget("barn")
        XCTAssertTrue(store.fields().isEmpty, "forgotten fields aren't listed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.appendingPathComponent("course.json").path), "but kept")
    }

    func testMeshesAndElevationLiveInTheFieldFolder() throws {
        try store.register(course("barn", "The Barn", version: 1), source: "x")
        let info = FieldMeshInfo(courseID: "barn", name: "Yard", frame: FieldFrame(origin: GeoPoint(latitude: 42.36, longitude: -71.06)),
                                 toENU: .identity, imageCount: 3, residualRMS: 1)
        try store.save(info)
        XCTAssertEqual(store.meshes(courseID: "barn").count, 1)
        XCTAssertEqual(store.fields().count, 1, "a mesh folder doesn't look like a field")
        XCTAssertEqual(store.capturesDirectory("barn").lastPathComponent, "captures")
    }
}
