import Foundation
import ImageIO
import UniformTypeIdentifiers
import CoreGraphics
import XCTest
import CoreGeo
import CourseKit
import FieldKit
@testable import FieldCapture

final class FieldCaptureTests: XCTestCase {
    let origin = GeoPoint(latitude: 42.3607, longitude: -71.0583)
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("FieldCaptureTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    // MARK: Fixtures

    /// Writes a tiny JPEG, with a GPS block if `gps` is given.
    @discardableResult
    private func writeJPEG(_ name: String, gps: [String: Any]?) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(ctx.makeImage())
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        var props: [String: Any] = [:]
        if let gps { props[kCGImagePropertyGPSDictionary as String] = gps }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return url
    }

    private func gps(lat: Double, lon: Double, alt: Double? = nil, accuracy: Double? = nil) -> [String: Any] {
        var d: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(lat),
            kCGImagePropertyGPSLatitudeRef as String: lat < 0 ? "S" : "N",
            kCGImagePropertyGPSLongitude as String: abs(lon),
            kCGImagePropertyGPSLongitudeRef as String: lon < 0 ? "W" : "E",
        ]
        if let alt {
            d[kCGImagePropertyGPSAltitude as String] = abs(alt)
            d[kCGImagePropertyGPSAltitudeRef as String] = alt < 0 ? 1 : 0
        }
        if let accuracy { d[kCGImagePropertyGPSHPositioningError as String] = accuracy }
        return d
    }

    // MARK: EXIF

    func testReadsGPSFromAGeneratedJPEG() throws {
        let url = try writeJPEG("a.jpg", gps: gps(lat: 42.3607, lon: -71.0583, alt: 12.5, accuracy: 4.2))
        let tag = try XCTUnwrap(PhotoGeotag.read(url))
        XCTAssertEqual(tag.point.latitude, 42.3607, accuracy: 1e-6)
        XCTAssertEqual(tag.point.longitude, -71.0583, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(tag.altitude), 12.5, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(tag.horizontalAccuracy), 4.2, accuracy: 1e-3)
    }

    func testSouthernWesternAndBelowSeaLevel() throws {
        let url = try writeJPEG("b.jpg", gps: gps(lat: -33.86, lon: 151.2, alt: -3))
        let tag = try XCTUnwrap(PhotoGeotag.read(url))
        XCTAssertEqual(tag.point.latitude, -33.86, accuracy: 1e-6)
        XCTAssertEqual(tag.point.longitude, 151.2, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(tag.altitude), -3, accuracy: 1e-3)
        XCTAssertNil(tag.horizontalAccuracy)
    }

    func testNoGPSAndBadGPS() throws {
        XCTAssertNil(PhotoGeotag.read(try writeJPEG("none.jpg", gps: nil)))
        let u = tmp.appendingPathComponent("x.jpg")
        XCTAssertNil(PhotoGeotag.parse(gps: [:], url: u))
        XCTAssertNil(PhotoGeotag.parse(gps: gps(lat: 0, lon: 0), url: u), "0,0 is a missing fix, not a place")
        XCTAssertNil(PhotoGeotag.parse(gps: [kCGImagePropertyGPSLatitude as String: 95.0,
                                             kCGImagePropertyGPSLongitude as String: 10.0], url: u))
        let zeroAcc = try XCTUnwrap(PhotoGeotag.parse(gps: gps(lat: 1, lon: 2, accuracy: 0), url: u))
        XCTAssertNil(zeroAcc.horizontalAccuracy)
    }

    func testFolderListsImagesAndSplitsUntagged() throws {
        try writeJPEG("IMG_10.jpg", gps: gps(lat: 42.36, lon: -71.05))
        try writeJPEG("IMG_2.JPG", gps: gps(lat: 42.36, lon: -71.05))
        try writeJPEG("IMG_3.jpeg", gps: nil)
        try Data("not a photo".utf8).write(to: tmp.appendingPathComponent("notes.txt"))
        let urls = try PhotoFolder.imageURLs(in: tmp)
        XCTAssertEqual(urls.map(\.lastPathComponent), ["IMG_2.JPG", "IMG_3.jpeg", "IMG_10.jpg"])
        let (tagged, untagged) = try PhotoFolder.geotags(in: tmp)
        XCTAssertEqual(tagged.count, 2)
        XCTAssertEqual(untagged.map(\.lastPathComponent), ["IMG_3.jpeg"])
    }

    // MARK: Pairing

    func testPairingByPathThenUniqueName() {
        let a = PhotoGeotag(url: URL(fileURLWithPath: "/photos/a.jpg"), point: origin)
        let b = PhotoGeotag(url: URL(fileURLWithPath: "/photos/b.jpg"), point: origin)
        let c = PhotoGeotag(url: URL(fileURLWithPath: "/photos/c.jpg"), point: origin)
        let cams: [URL: SIMD3<Double>] = [
            URL(fileURLWithPath: "/photos/./a.jpg"): SIMD3(1, 0, 0),       // same path, not normalised
            URL(fileURLWithPath: "/elsewhere/b.jpg"): SIMD3(2, 0, 0),      // matched by name
            URL(fileURLWithPath: "/photos/d.jpg"): SIMD3(3, 0, 0),         // no geotag
        ]
        let pairs = CameraPairing.pair(cameras: cams, geotags: [a, b, c])
        XCTAssertEqual(pairs.map(\.geotag.url.lastPathComponent), ["a.jpg", "b.jpg"])
        XCTAssertEqual(pairs.map(\.reconstructed.x), [1, 2])
    }

    func testPairingSkipsAmbiguousNames() {
        let a1 = PhotoGeotag(url: URL(fileURLWithPath: "/one/a.jpg"), point: origin)
        let a2 = PhotoGeotag(url: URL(fileURLWithPath: "/two/a.jpg"), point: origin)
        let pairs = CameraPairing.pair(cameras: [URL(fileURLWithPath: "/three/a.jpg"): .zero], geotags: [a1, a2])
        XCTAssertTrue(pairs.isEmpty)
    }

    // MARK: Georeferencing

    /// Cameras walked around a 30 × 20 m yard at chest height, seen by a reconstruction that is
    /// y-up, scaled, turned and shifted.
    private func scene(n: Int = 16, accuracy: Double? = 3, altitude: Double? = 20,
                       noise: Double = 0) -> (pairs: [CameraPair], enu: [SIMD3<Double>]) {
        let frame = FieldFrame(origin: origin, originAltitude: (altitude ?? 1.5) - 1.5)
        // ENU → model: y up (z_enu → y_model), then a turn about up, scale 0.25, offset.
        let enuToYUp = Similarity3(scale: 1, axis: SIMD3(1, 0, 0), angle: -.pi / 2, translation: .zero)
        let turn = Similarity3(scale: 0.25, axis: SIMD3(0, 1, 0), angle: 0.7, translation: SIMD3(3, -1, 2))
        var s: UInt64 = 42
        func r() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) * 2 - 1 }
        var pairs: [CameraPair] = [], enus: [SIMD3<Double>] = []
        for i in 0..<n {
            let t = Double(i) / Double(n) * 2 * .pi
            let enu = SIMD3(15 * cos(t) + 5, 10 * sin(t) - 3, 1.5)
            let model = turn.apply(enuToYUp.apply(enu))
            let gpsENU = enu + SIMD3(r(), r(), 0) * noise
            let geo = frame.geo(gpsENU)
            pairs.append(CameraPair(reconstructed: model,
                                    geotag: PhotoGeotag(url: URL(fileURLWithPath: "/p/\(i).jpg"), point: geo.point,
                                                        altitude: altitude.map { $0 + r() * noise },
                                                        horizontalAccuracy: accuracy)))
            enus.append(enu)
        }
        return (pairs, enus)
    }

    func testHorizontalFitRecoversThePlacement() throws {
        let (pairs, enus) = scene(accuracy: 5)
        let geo = try Georeference.fit(pairs, origin: origin)
        XCTAssertEqual(geo.mode, .horizontal)
        XCTAssertEqual(geo.toENU.scale, 4, accuracy: 1e-6)
        XCTAssertLessThan(geo.residualRMS, 1e-3)
        XCTAssertEqual(geo.frame.originAltitude, 18.5, accuracy: 1e-9)
        for (p, e) in zip(pairs, enus) {
            let v = geo.toENU.apply(p.reconstructed)
            XCTAssertEqual(v.x, e.x, accuracy: 1e-3); XCTAssertEqual(v.y, e.y, accuracy: 1e-3)
            XCTAssertEqual(v.z, 1.5, accuracy: 1e-3)
        }
        // Up in the model (y) is up in ENU.
        let up = geo.toENU.rotate(SIMD3(0, 1, 0))
        XCTAssertEqual(up.z, 1, accuracy: 1e-6)
    }

    func testThreeDOnlyWithGoodAltitudeEverywhere() {
        let good = PhotoGeotag(url: URL(fileURLWithPath: "/a"), point: origin, altitude: 10, horizontalAccuracy: 2)
        var noAlt = good; noAlt.altitude = nil
        var poor = good; poor.horizontalAccuracy = 8
        var unknown = good; unknown.horizontalAccuracy = nil
        XCTAssertEqual(Georeference.mode(for: [good, good, good]), .threeD)
        XCTAssertEqual(Georeference.mode(for: [good, good, noAlt]), .horizontal)
        XCTAssertEqual(Georeference.mode(for: [good, good, poor]), .horizontal)
        XCTAssertEqual(Georeference.mode(for: [good, good, unknown]), .horizontal)
        XCTAssertEqual(Georeference.mode(for: []), .horizontal)
    }

    func testThreeDFitUsesAltitude() throws {
        let (pairs, _) = scene(accuracy: 2, altitude: 30)
        let geo = try Georeference.fit(pairs, origin: origin)
        XCTAssertEqual(geo.mode, .threeD)
        XCTAssertEqual(geo.toENU.scale, 4, accuracy: 1e-6)
        XCTAssertLessThan(geo.residualRMS, 1e-3)
    }

    func testNoisyGPSAndAnOutlier() throws {
        var (pairs, enus) = scene(n: 24, accuracy: 4, noise: 1.5)
        // One photo's GPS is 40 m off; it's dropped and the rest still place the mesh.
        let bad = FieldFrame(origin: origin).geo(enus[5] + SIMD3(40, 0, 0)).point
        pairs[5].geotag.point = bad
        let geo = try Georeference.fit(pairs, origin: origin)
        XCTAssertEqual(geo.rejected.map(\.geotag.url.lastPathComponent), ["5.jpg"])
        XCTAssertEqual(geo.used.count, 23)
        XCTAssertEqual(geo.toENU.scale, 4, accuracy: 0.15)
        XCTAssertLessThan(geo.residualRMS, 2.5)
        XCTAssertEqual(geo.horizontalRMS, geo.residualRMS, accuracy: 1e-12)
    }

    func testWeightsFavourAccurateFixes() {
        let g = PhotoGeotag(url: URL(fileURLWithPath: "/a"), point: origin, horizontalAccuracy: 2)
        XCTAssertEqual(Georeference.weight(g), 0.25, accuracy: 1e-12)
        var none = g; none.horizontalAccuracy = nil
        XCTAssertEqual(Georeference.weight(none), 1 / 25, accuracy: 1e-12)
        var tiny = g; tiny.horizontalAccuracy = 0.1
        XCTAssertEqual(Georeference.weight(tiny), 1, accuracy: 1e-12, "clamped at 1 m")
    }

    func testRefusesTooFewOrCollinearCameras() {
        let (pairs, _) = scene()
        XCTAssertThrowsError(try Georeference.fit(Array(pairs.prefix(2)), origin: origin)) {
            XCTAssertEqual($0 as? Georeference.Failure, .tooFewCameras(2))
        }
        // Photos all taken along one straight path.
        let line = (0..<6).map { i in
            CameraPair(reconstructed: SIMD3(Double(i), 0, Double(i) * 0.1),
                       geotag: PhotoGeotag(url: URL(fileURLWithPath: "/l/\(i).jpg"),
                                           point: Geo.offset(origin, east: Double(i) * 4, north: 0)))
        }
        XCTAssertThrowsError(try Georeference.fit(line, origin: origin)) {
            XCTAssertEqual($0 as? Georeference.Failure, .camerasInALine)
        }
    }

    func testSavedMeshInfoRoundTrips() throws {
        let (pairs, _) = scene()
        let geo = try Georeference.fit(pairs, origin: origin)
        let info = FieldMeshInfo(courseID: "elm-st", name: "test", frame: geo.frame, toENU: geo.toENU,
                                 imageCount: pairs.count, residualRMS: geo.residualRMS)
        let store = FieldStore(root: tmp)
        _ = try store.save(info)
        let saved = try XCTUnwrap(store.meshes(courseID: "elm-st").first)
        XCTAssertEqual(saved.info.id, info.id)
        XCTAssertEqual(saved.info.imageCount, pairs.count)
        XCTAssertEqual(saved.info.toENU.scale, geo.toENU.scale, accuracy: 1e-12)
    }

    // MARK: Origin and command line

    func testOriginIsFlagOneThenBoundary() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("courses/sample-course.yaml")
        let course = try XCTUnwrap(CourseFile.load(data: try Data(contentsOf: url)).course)
        let o = try XCTUnwrap(MeshOrigin.origin(for: course))
        XCTAssertEqual(o.point, GeoPoint(latitude: 42.360729, longitude: -71.058280))
        XCTAssertEqual(o.label, "hole 1 flag")

        var bare = course
        bare.holes = []
        XCTAssertEqual(MeshOrigin.origin(for: bare)?.point, course.boundary.vertices[0])
        bare.boundary = GeoPolygon([])
        XCTAssertNil(MeshOrigin.origin(for: bare))
    }

    func testParsesTheCommandLine() throws {
        let c = try MeshCommand.parse(["shots", "--course", "c.yaml", "--name", "Spring", "--detail", "full",
                                       "--out", "/tmp/fields", "--dry-run"])
        XCTAssertEqual(c.photos.lastPathComponent, "shots")
        XCTAssertEqual(c.course.lastPathComponent, "c.yaml")
        XCTAssertEqual(c.name, "Spring")
        XCTAssertEqual(c.detail, .full)
        XCTAssertEqual(c.out?.path, "/tmp/fields")
        XCTAssertTrue(c.dryRun)

        let d = try MeshCommand.parse(["--course", "c.yaml", "shots"])
        XCTAssertEqual(d.detail, .medium)
        XCTAssertFalse(d.dryRun)
        XCTAssertNil(d.out)

        XCTAssertThrowsError(try MeshCommand.parse(["--help"])) { XCTAssertEqual($0 as? MeshCommand.ParseError, .help) }
        for bad in [["shots"], ["--course", "c.yaml"], ["shots", "--course"], ["shots", "--course", "c", "--detail", "ultra"],
                    ["shots", "more", "--course", "c"], ["shots", "--course", "c", "--frobnicate"]] {
            XCTAssertThrowsError(try MeshCommand.parse(bad), "\(bad)")
        }
    }
}
