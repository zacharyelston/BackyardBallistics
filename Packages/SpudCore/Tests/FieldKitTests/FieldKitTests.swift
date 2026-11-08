import Foundation
import XCTest
import CoreGeo
@testable import FieldKit

final class FieldKitTests: XCTestCase {
    let origin = GeoPoint(latitude: 42.36, longitude: -71.06)

    private func points(_ n: Int, seed: UInt64) -> [SIMD3<Double>] {
        var s = seed
        func r() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) * 40 - 20 }
        return (0..<n).map { _ in SIMD3(r(), r(), r() / 4) }
    }

    func testFitRecoversAKnownTransform() throws {
        let truth = Similarity3(scale: 2.3, axis: SIMD3(0.3, -0.5, 0.8), angle: 1.1, translation: SIMD3(12, -7, 3))
        let src = points(12, seed: 7)
        let dst = src.map(truth.apply)
        let fit = try XCTUnwrap(Similarity3.fit(from: src, to: dst))
        XCTAssertEqual(fit.scale, truth.scale, accuracy: 1e-9)
        XCTAssertEqual(fit.rms(from: src, to: dst), 0, accuracy: 1e-9)
        let (f, t) = (fit.matrix, truth.matrix)
        for (a, b) in [(f.0, t.0), (f.1, t.1), (f.2, t.2)] {
            for i in 0..<3 { XCTAssertEqual(a[i], b[i], accuracy: 1e-9) }
        }
    }

    func testFitWithGPSNoise() throws {
        // A reconstruction in arbitrary units, rotated and flipped about; GPS adds a few metres of noise.
        let truth = Similarity3(scale: 0.37, axis: SIMD3(1, 1, 0), angle: 2.5, translation: SIMD3(30, 40, 1))
        let src = points(40, seed: 3)
        var s: UInt64 = 99
        func noise() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return (Double(s >> 11) / Double(1 << 53) - 0.5) * 4 }
        let dst = src.map { truth.apply($0) + SIMD3(noise(), noise(), noise()) }
        let fit = try XCTUnwrap(Similarity3.fit(from: src, to: dst))
        // Uniform ±2 m on each axis is about 2.0 m RMS by itself: the fit should sit at that floor.
        XCTAssertEqual(fit.scale, truth.scale, accuracy: truth.scale * 0.05)
        XCTAssertLessThan(fit.rms(from: src, to: dst), 2.1)
        XCTAssertLessThan(truth.rms(from: src, to: dst) - fit.rms(from: src, to: dst), 0.2, "no worse than the truth")
        XCTAssertGreaterThanOrEqual(truth.rms(from: src, to: dst) + 1e-9, fit.rms(from: src, to: dst), "least squares beats the truth on its own data")
    }

    func testFitNeedsThreeSpreadPoints() {
        XCTAssertNil(Similarity3.fit(from: [.zero, SIMD3(1, 0, 0)], to: [.zero, SIMD3(1, 0, 0)]))
        XCTAssertNil(Similarity3.fit(from: [.zero, .zero, .zero], to: [.zero, SIMD3(1, 0, 0), SIMD3(0, 1, 0)]))
    }

    func testFrameRoundTrip() {
        let f = FieldFrame(origin: origin, originAltitude: 30)
        let p = Geo.offset(origin, east: 25, north: -40)
        let v = f.enu(p, altitude: 33)
        XCTAssertEqual(v.x, 25, accuracy: 0.01)
        XCTAssertEqual(v.y, -40, accuracy: 0.01)
        XCTAssertEqual(v.z, 3, accuracy: 1e-9)
        let back = f.geo(v)
        XCTAssertEqual(Geo.distance(back.point, p), 0, accuracy: 0.01)
        XCTAssertEqual(back.altitude, 33, accuracy: 1e-9)
    }

    func testElevationGrid() {
        let f = FieldFrame(origin: origin)
        // A plane rising 0.1 m per metre east, 0.05 per metre north.
        var h: [Double] = []
        for r in 0..<3 { for c in 0..<4 { h.append(Double(c) * 10 * 0.1 + Double(r) * 10 * 0.05) } }
        let g = ElevationGrid(frame: f, southWest: SIMD2(0, 0), spacing: 10, columns: 4, rows: 3, heights: h, source: "test")
        XCTAssertEqual(g.height(east: 15, north: 5) ?? .nan, 1.75, accuracy: 1e-9)
        XCTAssertEqual(g.height(east: 30, north: 20) ?? .nan, 4, accuracy: 1e-9)
        XCTAssertNil(g.height(east: -1, north: 0))
        let s = ElevationGrid.samplePoints(covering: [origin, Geo.offset(origin, east: 50, north: 30)], frame: f, spacing: 10, margin: 0)
        XCTAssertEqual(s.columns, 6)
        XCTAssertEqual(s.rows, 4)
        XCTAssertEqual(s.points.count, 24)
    }

    func testStoreSavesAndLists() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FieldStore(root: root)
        let a = FieldMeshInfo(courseID: "barn", name: "First", createdAt: Date(timeIntervalSince1970: 1_000_000),
                              frame: FieldFrame(origin: origin), toENU: .identity, imageCount: 40, residualRMS: 1.2)
        let b = FieldMeshInfo(courseID: "barn", name: "Second", createdAt: Date(timeIntervalSince1970: 2_000_000),
                              frame: FieldFrame(origin: origin), toENU: .identity, imageCount: 60, residualRMS: 0.9)
        _ = try store.save(a)
        _ = try store.save(b)
        XCTAssertEqual(store.meshes(courseID: "barn").map(\.info.name), ["Second", "First"])
        XCTAssertEqual(store.meshes(courseID: "barn").first?.mesh.lastPathComponent, "mesh.usdz")
        XCTAssertTrue(store.meshes(courseID: "other").isEmpty)
    }
}
