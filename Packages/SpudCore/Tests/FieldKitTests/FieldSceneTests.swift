import Foundation
import XCTest
import simd
import CoreGeo
@testable import FieldKit

final class FieldSceneTests: XCTestCase {
    let origin = GeoPoint(latitude: 42.36, longitude: -71.06)

    /// A plane rising 0.1 m per metre east and 0.05 per metre north from 30 m, 5 m spacing.
    private func slope(frameAltitude: Double = 30, nanAt: Int? = nil) -> ElevationGrid {
        var h: [Double] = []
        for r in 0..<4 { for c in 0..<5 { h.append(30 + Double(c) * 5 * 0.1 + Double(r) * 5 * 0.05) } }
        if let i = nanAt { h[i] = .nan }
        return ElevationGrid(frame: FieldFrame(origin: origin, originAltitude: frameAltitude), southWest: SIMD2(-10, -5),
                             spacing: 5, columns: 5, rows: 4, heights: h, source: "test")
    }

    private func close(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ tol: Double = 1e-9, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), tol, "\(a) vs \(b)", file: file, line: line)
    }

    // MARK: Axes

    func testSceneAxesAreEastUpSouth() {
        close(SceneAxes.scene(SIMD3(1, 0, 0)), SIMD3(1, 0, 0))    // east → +x
        close(SceneAxes.scene(SIMD3(0, 1, 0)), SIMD3(0, 0, -1))   // north → −z
        close(SceneAxes.scene(SIMD3(0, 0, 1)), SIMD3(0, 1, 0))    // up → +y
        close(SceneAxes.scene(SIMD3(0, 0, 2), exaggeration: 2), SIMD3(0, 4, 0))
        let v = SIMD3(3.0, -4.0, 5.0)
        close(SceneAxes.enu(SceneAxes.scene(v, exaggeration: 2), exaggeration: 2), v)
        close(SceneAxes.matrix(exaggeration: 2) * v, SceneAxes.scene(v, exaggeration: 2))
        // Still right-handed: a proper rotation (det +1) before exaggeration.
        XCTAssertEqual(SceneAxes.matrix().determinant, 1, accuracy: 1e-12)
    }

    func testMeshTransformPlacesUSDYUpMeshInTheScene() {
        // A mesh as USD stores it, y up: its +y must come out as the scene's up, its −z as north.
        // toENU for such a mesh, scaled 2× and 10 m east, is the y-up → z-up rotation (+90° about x).
        let toENU = Similarity3(scale: 2, axis: SIMD3(1, 0, 0), angle: .pi / 2, translation: SIMD3(10, 0, 0))
        close(toENU.apply(SIMD3(0, 1, 0)), SIMD3(10, 0, 2))    // mesh up → ENU up
        close(toENU.apply(SIMD3(0, 0, -1)), SIMD3(10, 2, 0))   // mesh −z → ENU north
        let meshFrame = FieldFrame(origin: Geo.offset(origin, east: 5, north: 7), originAltitude: 33)
        let sceneFrame = FieldFrame(origin: origin, originAltitude: 30)
        let m = SceneAxes.meshTransform(toENU: toENU, meshFrame: meshFrame, sceneFrame: sceneFrame)
        for p in [SIMD3(0.0, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 2, -3), SIMD3(-4, 0.5, 6)] {
            let viaMatrix = m * SIMD4(p, 1)
            // The long way round: mesh → ENU in the mesh frame → GPS → ENU in the scene frame → scene.
            let enuMesh = toENU.apply(p)
            let geo = meshFrame.geo(enuMesh)
            let expected = SceneAxes.scene(sceneFrame.enu(geo.point, altitude: geo.altitude))
            close(SIMD3(viaMatrix.x, viaMatrix.y, viaMatrix.z), expected, 0.01)
            XCTAssertEqual(viaMatrix.w, 1)
        }
        // Mesh up (0, 1, 0) is straight up in the scene: same x/z as the mesh origin, 2 m higher.
        let o = m * SIMD4(0, 0, 0, 1), up = m * SIMD4(0, 1, 0, 1)
        close(SIMD3(up.x - o.x, up.y - o.y, up.z - o.z), SIMD3(0, 2, 0), 1e-9)
        // With exaggeration only the up axis stretches.
        let m2 = SceneAxes.meshTransform(toENU: toENU, meshFrame: meshFrame, sceneFrame: sceneFrame, exaggeration: 2)
        let o2 = m2 * SIMD4(0, 0, 0, 1), up2 = m2 * SIMD4(0, 1, 0, 1)
        close(SIMD3(up2.x - o2.x, up2.y - o2.y, up2.z - o2.z), SIMD3(0, 4, 0), 1e-9)
        XCTAssertEqual(o2.x, o.x, accuracy: 1e-9)
        XCTAssertEqual(o2.y, 2 * o.y, accuracy: 1e-9)
    }

    // MARK: Terrain

    func testTerrainMesh() {
        let g = slope()
        let t = TerrainMesh(grid: g)
        XCTAssertEqual(t.positions.count, 20)
        XCTAssertEqual(t.indices.count, 4 * 3 * 6)
        // South-west sample: ENU (−10, −5, 0) → scene (−10, 0, 5). North-east: (10, 10, 2.75) → (10, 2.75, −10).
        XCTAssertEqual(t.positions[0], SIMD3<Float>(-10, 0, 5))
        XCTAssertEqual(t.positions[19], SIMD3<Float>(10, 2.75, -10))
        XCTAssertEqual(t.heightFraction[0], 0)
        XCTAssertEqual(t.heightFraction[19], 1)
        // Every triangle faces up (counter-clockwise from above).
        for i in stride(from: 0, to: t.indices.count, by: 3) {
            let a = t.positions[Int(t.indices[i])], b = t.positions[Int(t.indices[i + 1])], c = t.positions[Int(t.indices[i + 2])]
            XCTAssertGreaterThan(simd_cross(b - a, c - a).y, 0)
        }
        // The plane's normal ∝ (−0.1, 1, 0.05) in scene axes (rises east, rises north = −z).
        let n = simd_normalize(SIMD3<Float>(-0.1, 1, 0.05))
        for v in t.normals { XCTAssertLessThan(simd_length(v - n), 1e-5) }
        // Exaggeration doubles heights and steepens normals.
        let t2 = TerrainMesh(grid: g, exaggeration: 2)
        XCTAssertEqual(t2.positions[19].y, 5.5, accuracy: 1e-5)
        XCTAssertLessThan(simd_length(t2.normals[7] - simd_normalize(SIMD3<Float>(-0.2, 1, 0.1))), 1e-5)
    }

    func testNaNIsFilledAndFlatFallback() {
        let g = slope(nanAt: 7)
        XCTAssertEqual(g.validCount, 19)
        XCTAssertTrue(TerrainMesh(grid: g).positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        // No data at all (outside the US): flat at the origin altitude.
        var none = slope()
        none.heights = Array(repeating: .nan, count: 20)
        XCTAssertNil(none.heightRange)
        XCTAssertTrue(TerrainMesh(grid: none).positions.allSatisfy { $0.y == 0 })
        XCTAssertTrue(TerrainMesh(grid: none).heightFraction.allSatisfy { $0 == 0.5 })
        let flat = ElevationGrid.flat(covering: [origin, Geo.offset(origin, east: 40, north: 30)], frame: FieldFrame(origin: origin))
        XCTAssertEqual(flat.validCount, flat.columns * flat.rows)
        XCTAssertEqual(flat.heightRange, 0...0)
    }

    func testCacheJSONKeepsNaN() throws {
        let g = slope(nanAt: 3)
        let back = try ElevationGrid.decodeJSON(g.encodedJSON())
        XCTAssertTrue(back.heights[3].isNaN)
        XCTAssertEqual(back.validCount, 19)
        XCTAssertEqual(back.heights[4], g.heights[4])
        XCTAssertEqual(back.frame, g.frame)
    }

    func testSpacingCoarsensForBigCourses() {
        let f = FieldFrame(origin: origin)
        let yard = [origin, Geo.offset(origin, east: 120, north: 150)]
        XCTAssertEqual(ElevationGrid.spacing(covering: yard, frame: f), 2.5)
        let farm = [origin, Geo.offset(origin, east: 1500, north: 1200)]
        let s = ElevationGrid.spacing(covering: farm, frame: f, maxSamples: 12_000)
        XCTAssertGreaterThan(s, 2.5)
        XCTAssertLessThanOrEqual(ElevationGrid.samplePoints(covering: farm, frame: f, spacing: s).points.count, 12_000)
        XCTAssertGreaterThan(ElevationGrid.samplePoints(covering: farm, frame: f, spacing: s - 0.5).points.count, 12_000)
    }

    func testFrameAndCoverage() {
        let corners = [origin, Geo.offset(origin, east: 100, north: 0), Geo.offset(origin, east: 100, north: 60)]
        let f = ElevationGrid.frame(covering: corners)
        let mid = f.enu(origin)
        XCTAssertEqual(mid.x, -50, accuracy: 0.05)
        XCTAssertEqual(mid.y, -30, accuracy: 0.05)
        let s = ElevationGrid.samplePoints(covering: corners, frame: f, spacing: 5)
        let g = ElevationGrid(frame: f, southWest: s.southWest, spacing: 5, columns: s.columns, rows: s.rows,
                              heights: Array(repeating: 0, count: s.points.count), source: "t")
        XCTAssertTrue(g.covers(corners))
        XCTAssertFalse(g.covers([Geo.offset(origin, east: 200, north: 0)]))
    }

    // MARK: Draping

    func testDrapedLineFollowsTheGround() {
        let g = slope()
        let line = Drape.line([SIMD2(-10, -5), SIMD2(10, -5)], on: g, step: 1)
        XCTAssertEqual(line.count, 21)
        for p in line { XCTAssertEqual(p.z, 0.1 * (p.x + 10), accuracy: 1e-9) }   // 30 + … − origin altitude 30
        // Off the grid: clamped to its edge, never NaN.
        let off = Drape.line([SIMD2(-50, -50), SIMD2(50, 50)], on: g, step: 10)
        XCTAssertTrue(off.allSatisfy { !$0.z.isNaN })
        XCTAssertEqual(off.first!.z, 0, accuracy: 1e-9)
        XCTAssertEqual(off.last!.z, 2.75, accuracy: 1e-9)
        // A closed square comes back to its start.
        let sq = Drape.line([SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4)], on: g, step: 2, closed: true)
        XCTAssertEqual(sq.count, 9)
        XCTAssertEqual(sq.first, sq.last)
    }

    func testGroundEnvelope() {
        // On the plane, the highest point within 5 m is 5 m along the steepest way up (0.1, 0.05).
        let g = slope()
        let z = g.groundZ(east: 0, north: 0, within: 5)
        XCTAssertGreaterThanOrEqual(z, g.groundZ(east: 0, north: 0))
        XCTAssertGreaterThanOrEqual(z, g.groundZ(east: 5, north: 0) - 1e-9)
        XCTAssertLessThanOrEqual(z, g.groundZ(east: 0, north: 0) + 5 * (0.1 * 0.1 + 0.05 * 0.05).squareRoot() + 1e-9)
        XCTAssertEqual(g.groundZ(east: 0, north: 0, within: 0), g.groundZ(east: 0, north: 0))
    }

    func testCircle() {
        let c = Drape.circle(centre: SIMD2(3, 4), radius: 1.5, segments: 12)
        XCTAssertEqual(c.count, 12)
        for p in c { XCTAssertEqual(simd_length(p - SIMD2(3, 4)), 1.5, accuracy: 1e-12) }
    }

    func testWedge() {
        // From the origin toward due east: bearing 90°, ±30°, 96 m.
        let w = Drape.wedge(apex: .zero, toward: SIMD2(10, 0), halfAngle: 30, range: 96, radialStep: 4, angleStep: 3)
        XCTAssertEqual(w.points.count, 1 + 24 * 21)
        for p in w.points.dropFirst() {
            let r = simd_length(p)
            XCTAssertLessThanOrEqual(r, 96 + 1e-9)
            let bearing = atan2(p.x, p.y) * 180 / .pi
            XCTAssertGreaterThanOrEqual(bearing, 60 - 1e-9)
            XCTAssertLessThanOrEqual(bearing, 120 + 1e-9)
        }
        // The far edge reaches the full range at both sides.
        XCTAssertEqual(simd_length(w.points.last!), 96, accuracy: 1e-9)
        // Every triangle faces up: counter-clockwise in east/north.
        for i in stride(from: 0, to: w.indices.count, by: 3) {
            let a = w.points[Int(w.indices[i])], b = w.points[Int(w.indices[i + 1])], c = w.points[Int(w.indices[i + 2])]
            let cross = (b - a).x * (c - a).y - (b - a).y * (c - a).x
            XCTAssertGreaterThan(cross, 0)
        }
    }

    // MARK: USGS

    func testSamplesRequestAndParse() throws {
        let body = String(decoding: USGSElevation.samplesBody([GeoPoint(latitude: 42.3607, longitude: -71.0583)]), as: UTF8.self)
        XCTAssertTrue(body.contains("geometryType=esriGeometryMultipoint"))
        XCTAssertTrue(body.contains("returnFirstValueOnly=true"))
        XCTAssertTrue(body.contains("%5B-71.05830000%2C42.36070000%5D"), body)   // [lon,lat]
        XCTAssertTrue(body.contains("wkid%22%3A4326"))
        // As the service answers: point 2 had no data and is left out; point 1 says NoData.
        let json = """
        {"samples":[{"location":{"x":-71.0583,"y":42.3607},"locationId":0,"value":"6.528657436","resolution":1},
                    {"location":{"x":-71.0576,"y":42.3614},"locationId":1,"value":"NoData"},
                    {"location":{"x":-71.0576,"y":42.3614},"locationId":3,"value":"3.71"}]}
        """
        let h = try USGSElevation.parseSamples(Data(json.utf8), count: 4)
        XCTAssertEqual(h[0], 6.528657436, accuracy: 1e-9)
        XCTAssertTrue(h[1].isNaN)
        XCTAssertTrue(h[2].isNaN)
        XCTAssertEqual(h[3], 3.71, accuracy: 1e-9)
        XCTAssertThrowsError(try USGSElevation.parseSamples(Data("{\"error\":{\"code\":400,\"message\":\"bad\"}}".utf8), count: 1)) {
            XCTAssertEqual($0 as? USGSElevation.ParseError, .serviceError("bad"))
        }
        XCTAssertThrowsError(try USGSElevation.parseSamples(Data("Call failed.".utf8), count: 1))
    }

    func testPointQuery() {
        let url = USGSElevation.pointQuery(GeoPoint(latitude: 42.3607, longitude: -71.0583)).absoluteString
        XCTAssertTrue(url.hasPrefix("https://epqs.nationalmap.gov/v1/json?"))
        XCTAssertTrue(url.contains("x=-71.05830000") && url.contains("y=42.36070000") && url.contains("units=Meters"))
        XCTAssertEqual(USGSElevation.parsePointQuery(Data("{\"value\":\"6.52\"}".utf8)), 6.52, accuracy: 1e-9)
        XCTAssertEqual(USGSElevation.parsePointQuery(Data("{\"value\":12.5}".utf8)), 12.5, accuracy: 1e-9)
        XCTAssertTrue(USGSElevation.parsePointQuery(Data("{\"value\":-1000000}".utf8)).isNaN)
        XCTAssertTrue(USGSElevation.parsePointQuery(Data("Call failed.".utf8)).isNaN)
    }
}
