import CoreGeo
import Foundation
import XCTest
@testable import ZoneKit

final class ZoneKitTests: XCTestCase {
    let origin = GeoPoint(latitude: 42.36, longitude: -71.06)
    let time = Date(timeIntervalSince1970: 1_800_000_000)
    func point(_ east: Double, _ north: Double = 0) -> GeoPoint { Geo.offset(origin, east: east, north: north) }
    func fix(_ east: Double, _ seconds: Double, accuracy: Double = 3) -> ZoneFix {
        ZoneFix(at: point(east), accuracy: accuracy, time: time.addingTimeInterval(seconds))
    }
    func zone(_ rule: ZoneRule = .goal) -> ZoneDefinition {
        ZoneDefinition(name: "Rally", shape: .circle(center: origin, radius: 100), rule: rule)
    }

    func testCircleAndConcavePolygonClearance() {
        XCTAssertEqual(zone().shape.clearance(at: origin), 100, accuracy: 0.01)
        XCTAssertEqual(zone().shape.clearance(at: point(120)), -20, accuracy: 0.01)
        let polygon = ZoneShape.polygon(vertices: [point(-50,-50),point(50,-50),point(50,0),point(0,0),point(0,50),point(-50,50)])
        XCTAssertNil(polygon.validationError)
        XCTAssertGreaterThan(polygon.clearance(at: point(-25,25)), 20)
        XCTAssertLessThan(polygon.clearance(at: point(25,25)), -20)
        XCTAssertEqual(polygon.clearance(at: point(0,25)), 0, accuracy: 0.01)
    }

    func testRejectsInvalidAndCrossedShapes() {
        for shape in [ZoneShape.circle(center: origin, radius: .nan), .circle(center: origin, radius: -1),
                      .polygon(vertices: [origin, point(50)]),
                      .polygon(vertices: [point(-50,-50),point(50,50),point(-50,50),point(50,-50)]),
                      .polygon(vertices: [origin,point(20),point(40)])] {
            XCTAssertNotNil(shape.validationError)
        }
    }

    func testArrivalRequiresBaselineAndTwoDistinctReportsAndDoesNotRepeat() {
        var tracker = ZoneTracker<String>(); let z = zone()
        func observe(_ east: Double, _ seconds: Double) -> [ZoneCrossing] {
            tracker.observe(fix(east,seconds), subject: "Ben", zones: [z], now: time.addingTimeInterval(seconds))
        }
        XCTAssertTrue(observe(150,0).isEmpty)
        XCTAssertTrue(observe(150,10).isEmpty)
        XCTAssertTrue(observe(0,20).isEmpty)
        XCTAssertTrue(observe(0,20).isEmpty) // replay isn't a second fix
        let crossed = observe(0,30)
        XCTAssertEqual(crossed.map(\.kind), [.arrived])
        XCTAssertTrue(observe(0,40).isEmpty)
        XCTAssertTrue(observe(150,50).isEmpty)
        XCTAssertTrue(observe(150,60).isEmpty) // goal departures aren't alerts
        XCTAssertTrue(observe(0,70).isEmpty)
        XCTAssertEqual(observe(0,80).map(\.kind), [.arrived])
    }

    func testAllowedAreaDoesNotInventDepartureForFirstOutsideFix() {
        var tracker = ZoneTracker<Int>(); let z = zone(.allowedArea)
        var output: [ZoneCrossing] = []
        for (i,east) in [150.0,150,0,0,150,150,150].enumerated() {
            output += tracker.observe(fix(east,Double(i*10)), subject: 1, zones: [z], now: time.addingTimeInterval(Double(i*10)))
        }
        XCTAssertEqual(output.map(\.kind), [.left])
    }

    func testJitterPoorAccuracyInvalidStaleAndOutOfOrderFixesDoNotTrigger() {
        var tracker = ZoneTracker<Int>(); let z = zone(.allowedArea)
        func run(_ east: Double, _ sec: Double, accuracy: Double = 3, received: Double? = nil) -> [ZoneCrossing] {
            tracker.observe(fix(east,sec,accuracy: accuracy), subject: 1, zones: [z], now: time.addingTimeInterval(received ?? sec))
        }
        XCTAssertTrue(run(0,0).isEmpty); XCTAssertTrue(run(0,10).isEmpty)
        XCTAssertTrue(run(101,20).isEmpty); XCTAssertTrue(run(99,30).isEmpty)
        XCTAssertTrue(run(150,40,accuracy:100).isEmpty)
        XCTAssertTrue(run(150,50,received:250).isEmpty)
        XCTAssertTrue(run(150,260).isEmpty); XCTAssertTrue(run(150,270).isEmpty)
        XCTAssertTrue(run(0,265).isEmpty) // out of order
        XCTAssertTrue(run(0,280,accuracy:.nan).isEmpty)
    }

    func testReconnectAndEditedZoneRebaseline() {
        var tracker = ZoneTracker<Int>(); var z = zone(.allowedArea)
        for s in [0.0,10] { _ = tracker.observe(fix(0,s),subject:1,zones:[z],now:time.addingTimeInterval(s)) }
        tracker.reset(member:1)
        for s in [20.0,30] { XCTAssertTrue(tracker.observe(fix(150,s),subject:1,zones:[z],now:time.addingTimeInterval(s)).isEmpty) }
        z.shape = .circle(center:point(300),radius:100)
        for s in [40.0,50] { XCTAssertTrue(tracker.observe(fix(0,s),subject:1,zones:[z],now:time.addingTimeInterval(s)).isEmpty) }
    }

    func testPolygonDepartureAndSerialization() throws {
        let z = ZoneDefinition(name:"Search",shape:.polygon(vertices:[point(-100,-100),point(100,-100),point(100,100),point(-100,100)]),rule:.allowedArea)
        XCTAssertEqual(try JSONDecoder().decode(ZoneDefinition.self,from:JSONEncoder().encode(z)),z)
        var tracker = ZoneTracker<String>(), events:[ZoneCrossing] = []
        for (i,east) in [0.0,0,150,150].enumerated() {
            events += tracker.observe(fix(east,Double(i*10)),subject:"Ana",zones:[z],now:time.addingTimeInterval(Double(i*10)))
        }
        XCTAssertEqual(events.map(\.kind),[.left])
    }
}
