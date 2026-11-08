// spud-mesh: a folder of photos of a backyard course to a georeferenced 3D mesh for the Theater
// host (docs/MESHING.md). Object Capture (RealityKit's PhotogrammetrySession) builds the USDZ and
// each photo's camera pose; FieldCapture fits those cameras to the photos' GPS in the course's
// ENU frame; FieldStore saves mesh.usdz and mesh.json where the Theater app looks.
//
//   swift run --package-path Packages/SpudCore spud-mesh <photos> --course <course.yaml> [--dry-run]
//
// The mesh is display only: nothing here feeds SafetyKit.

#if os(macOS)
import Foundation
import RealityKit
import CoreGeo
import CourseKit
import FieldKit
import FieldCapture

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("spud-mesh: \(message)\n".utf8))
    exit(code)
}

func f(_ x: Double, _ digits: Int = 2) -> String { String(format: "%.\(digits)f", x) }

// MARK: Arguments, course, photos

setvbuf(stdout, nil, _IOLBF, 0)   // progress shows promptly when piped

let command: MeshCommand
do {
    command = try MeshCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch MeshCommand.ParseError.help {
    print(MeshCommand.usage)
    exit(0)
} catch {
    fail("\(error)", code: 2)
}

guard let courseData = FileManager.default.contents(atPath: command.course.path) else {
    fail("can't read the course file \(command.course.path).")
}
let loaded = CourseFile.load(data: courseData)
guard let course = loaded.course else {
    fail("the course file has errors:\n" + loaded.problems.map { "  \($0)" }.joined(separator: "\n"))
}
guard let origin = MeshOrigin.origin(for: course) else {
    fail("the course has no flags and no boundary, so there is no origin for the mesh's frame.")
}

let (geotags, untagged): ([PhotoGeotag], [URL])
do {
    (geotags, untagged) = try PhotoFolder.geotags(in: command.photos)
} catch {
    fail("can't read the photos folder \(command.photos.path): \(error.localizedDescription)")
}
let photoCount = geotags.count + untagged.count
let name = command.name ?? command.photos.lastPathComponent
let store = FieldStore(root: command.out ?? FieldStore.defaultRoot)
let mode = Georeference.mode(for: geotags)

print("Course:  \(course.name) (\(course.id)); frame origin at \(origin.label), \(origin.point.latitude), \(origin.point.longitude)")
print("Photos:  \(photoCount) in \(command.photos.path), \(geotags.count) with GPS")
if !untagged.isEmpty {
    let names = untagged.prefix(5).map(\.lastPathComponent).joined(separator: ", ")
    print("         no GPS: \(names)\(untagged.count > 5 ? " and \(untagged.count - 5) more" : "")")
}
if !geotags.isEmpty {
    let acc = geotags.compactMap(\.horizontalAccuracy).sorted()
    let alt = geotags.filter { $0.altitude != nil }.count
    let frame = Georeference.frame(origin: origin.point, geotags: geotags)
    let far = geotags.map { Geo.distance($0.point, origin.point) }.max() ?? 0
    print("GPS:     \(acc.isEmpty ? "no accuracy in EXIF (assuming 5 m)" : "accuracy \(f(acc[0], 1))–\(f(acc[acc.count - 1], 1)) m, median \(f(acc[acc.count / 2], 1)) m"); \(alt) with altitude; farthest \(f(far, 0)) m from the origin")
    print("Fit:     \(mode == .threeD ? "3D (every photo has altitude and accuracy ≤ 3 m)" : "horizontal (GPS altitude not trusted; cameras assumed at chest height)"); frame height \(f(frame.originAltitude, 1)) m")
}
print("Mesh:    \"\(name)\", detail \(command.detail.rawValue), into \(store.courseDirectory(course.id).appendingPathComponent("meshes").path)")

guard geotags.count >= 3 else {
    fail("only \(geotags.count) photo\(geotags.count == 1 ? " has" : "s have") GPS; at least 3 geotagged photos are needed to place the mesh. Turn on Location for the Camera app (docs/MESHING.md).")
}
if command.dryRun {
    print("Dry run: photogrammetry not run.")
    exit(0)
}

// MARK: Photogrammetry

guard PhotogrammetrySession.isSupported else {
    fail("Object Capture isn't supported on this Mac (it needs Apple silicon, or a Mac with a GPU that supports ray tracing).")
}

let detail: PhotogrammetrySession.Request.Detail = switch command.detail {
case .reduced: .reduced
case .medium: .medium
case .full: .full
case .raw: .raw
}

let info0 = FieldMeshInfo(courseID: course.id, name: name, frame: FieldFrame(origin: origin.point),
                          toENU: .identity, imageCount: photoCount, residualRMS: 0)
let meshDir = store.meshDirectory(courseID: course.id, id: info0.id)
let meshURL = meshDir.appendingPathComponent(info0.meshFile)
do {
    try FileManager.default.createDirectory(at: meshDir, withIntermediateDirectories: true)
} catch {
    fail("can't create \(meshDir.path): \(error.localizedDescription)")
}
func cleanUpAndFail(_ message: String) -> Never {
    try? FileManager.default.removeItem(at: meshDir)
    fail(message)
}

var configuration = PhotogrammetrySession.Configuration()
configuration.sampleOrdering = .unordered
configuration.featureSensitivity = .normal

let session: PhotogrammetrySession
do {
    session = try PhotogrammetrySession(input: command.photos, configuration: configuration)
    try session.process(requests: [.modelFile(url: meshURL, detail: detail), .poses])
} catch {
    cleanUpAndFail("Object Capture couldn't start: \(error)")
}

/// Camera centres in the model's frame, by photo URL.
var cameras: [URL: SIMD3<Double>] = [:]
var modelDone = false
var lastShown: [String: Int] = [:]

func label(_ request: PhotogrammetrySession.Request) -> String {
    switch request {
    case .modelFile: return "model"
    case .poses: return "poses"
    default: return "request"
    }
}

do {
    outputs: for try await output in session.outputs {
        switch output {
        case .requestProgress(let request, let fraction):
            let pct = Int(fraction * 100) / 5 * 5, key = label(request)
            if pct != lastShown[key] {
                lastShown[key] = pct
                print("  \(key) \(pct)%")
            }
        case .requestComplete(let request, let result):
            switch result {
            case .modelFile(let url):
                modelDone = true
                print("  model written: \(url.path)")
            case .poses(let poses):
                for (sample, pose) in poses.posesBySample {
                    guard let url = poses.urlsBySample[sample] else { continue }
                    let t = pose.translation
                    cameras[url] = SIMD3(Double(t.x), Double(t.y), Double(t.z))
                }
                print("  poses: \(cameras.count) cameras placed")
            default:
                print("  \(label(request)) complete")
            }
        case .requestError(let request, let error):
            cleanUpAndFail("Object Capture failed (\(label(request))): \(error)")
        case .invalidSample(let id, let reason):
            print("  skipped sample \(id): \(reason)")
        case .skippedSample(let id):
            print("  skipped sample \(id)")
        case .automaticDownsampling:
            print("  note: images downsampled to fit in memory")
        case .processingCancelled:
            cleanUpAndFail("processing was cancelled.")
        case .processingComplete:
            break outputs
        default:
            break
        }
    }
} catch {
    cleanUpAndFail("Object Capture failed: \(error)")
}

guard modelDone, FileManager.default.fileExists(atPath: meshURL.path) else {
    cleanUpAndFail("Object Capture finished without writing a model.")
}

// MARK: Georeference and save

let pairs = CameraPairing.pair(cameras: cameras, geotags: geotags)
let geo: Georeference
do {
    geo = try Georeference.fit(pairs, origin: origin.point)
} catch {
    cleanUpAndFail("\(error)")
}

var info = info0
info.frame = geo.frame
info.toENU = geo.toENU
info.residualRMS = geo.residualRMS
do {
    _ = try store.save(info)
} catch {
    cleanUpAndFail("can't write mesh.json: \(error.localizedDescription)")
}

print("""

    Done.
      images:      \(photoCount) (\(geotags.count) with GPS, \(cameras.count) cameras reconstructed)
      poses used:  \(geo.used.count)\(geo.rejected.isEmpty ? "" : " (\(geo.rejected.count) dropped as GPS outliers: \(geo.rejected.map(\.geotag.url.lastPathComponent).joined(separator: ", ")))")
      fit:         \(geo.mode == .threeD ? "3D" : "horizontal"), scale \(f(geo.toENU.scale, 4)) m per model unit
      RMS:         \(f(geo.residualRMS)) m (east/north \(f(geo.horizontalRMS)) m)
      output:      \(meshDir.path)
    """)
if geo.residualRMS > 5 {
    print("  warning: the cameras sit more than 5 m from their GPS on average; check the mesh's placement before use.")
}
#else
import Foundation
FileHandle.standardError.write(Data("spud-mesh runs on macOS only (it needs RealityKit's PhotogrammetrySession).\n".utf8))
exit(1)
#endif
