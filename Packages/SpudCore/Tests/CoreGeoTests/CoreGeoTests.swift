import XCTest
@testable import CoreGeo

final class CoreGeoTests: XCTestCase {
    let origin = GeoPoint(latitude: 42.3601, longitude: -71.0589)

    func testOffsetRoundTrip() {
        let p = Geo.offset(origin, east: 30, north: 40)
        XCTAssertEqual(Geo.distance(origin, p), 50, accuracy: 0.01)
        let en = Geo.eastNorth(of: p, from: origin)
        XCTAssertEqual(en.east, 30, accuracy: 0.01)
        XCTAssertEqual(en.north, 40, accuracy: 0.01)
    }

    func testBearingAndDestination() {
        let east = Geo.offset(origin, east: 50, north: 0)
        XCTAssertEqual(Geo.bearing(from: origin, to: east), 90, accuracy: 0.01)
        let back = Geo.destination(origin, bearing: 225, distance: 70)
        XCTAssertEqual(Geo.bearing(from: origin, to: back), 225, accuracy: 0.01)
        XCTAssertEqual(Geo.distance(origin, back), 70, accuracy: 0.01)
    }

    func testARWorldToEastNorth() {
        let en = Geo.eastNorth(arOffset: 3, -60) // ARKit -Z is north
        XCTAssertEqual(en.east, 3)
        XCTAssertEqual(en.north, 60)
    }

    func testPolygonContains() {
        let square = GeoPolygon([Geo.offset(origin, east: -10, north: -10), Geo.offset(origin, east: 10, north: -10),
                                 Geo.offset(origin, east: 10, north: 10), Geo.offset(origin, east: -10, north: 10)])
        XCTAssertTrue(square.contains(origin))
        XCTAssertTrue(square.contains(Geo.offset(origin, east: 9, north: -9)))
        XCTAssertFalse(square.contains(Geo.offset(origin, east: 11, north: 0)))
        XCTAssertFalse(GeoPolygon([origin]).contains(origin))
    }
}
