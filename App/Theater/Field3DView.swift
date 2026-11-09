import SwiftUI
import AppKit
import SceneKit
import simd
import CoreGeo
import CourseKit
import GroupKit
import FieldKit

// The 3D view of the course, next to the 2D site map: USGS 3DEP terrain, the boundary, flags,
// rings, firing points and safety fans draped on it, the members at their GPS, and any field meshes
// saved for the course. Watching only, like the rest of the Theater. Scene axes: CourseScene.swift.

/// Heights and meshes per course, loaded once and kept for the session.
@MainActor
final class FieldModel: ObservableObject {
    enum Elevation {
        case loading
        case ready(ElevationGrid, cached: Bool)
        case failed(String)
    }

    struct Mesh: Identifiable {
        var info: FieldMeshInfo
        var url: URL
        var id: UUID { info.id }
    }

    @Published var elevation: [String: Elevation] = [:]
    @Published var meshes: [String: [Mesh]] = [:]
    let service = ElevationService()

    func load(_ course: Course, force: Bool = false) async {
        meshes[course.id] = service.store.meshes(courseID: course.id).map { Mesh(info: $0.info, url: $0.mesh) }
        if !force {
            switch elevation[course.id] {
            case .loading, .ready: return
            default: break
            }
        }
        elevation[course.id] = .loading
        do {
            let r = try await service.grid(courseID: course.id, boundary: course.boundary.vertices)
            elevation[course.id] = .ready(r.grid, cached: r.cached)
        } catch {
            elevation[course.id] = .failed(error.localizedDescription)
        }
    }
}

struct Field3DView: View {
    /// The watched squads, as the site map gets them.
    let squads: [SiteMapSquad]
    @StateObject private var field = FieldModel()
    @State private var courseID: String?
    @State private var exaggerate = false
    @State private var showMeshes = true
    @State private var resetCount = 0

    static let squadColors: [NSColor] = [.systemOrange, .cyan, .systemPink, .systemYellow, .systemMint, .systemPurple]

    private var courses: [Course] {
        var seen = Set<String>()
        return squads.compactMap(\.course).filter { seen.insert($0.id).inserted }
    }

    private var course: Course? { courses.first { $0.id == courseID } ?? courses.first }

    var body: some View {
        if let course {
            content(course)
                .task(id: course.id) { await field.load(course) }
        } else {
            ContentUnavailableView("No course yet", systemImage: "mountain.2",
                                   description: Text("The 3D view shows a watched squad's course once its iPad sends it."))
        }
    }

    private func content(_ course: Course) -> some View {
        let state = field.elevation[course.id]
        let grid: ElevationGrid
        var hasData = false
        if case let .ready(g, _) = state {
            grid = g
            hasData = g.validCount > 0
        } else {
            grid = ElevationGrid.flat(covering: course.boundary.vertices, frame: ElevationGrid.frame(covering: course.boundary.vertices))
        }
        let meshes = field.meshes[course.id] ?? []
        return TimelineView(.periodic(from: .now, by: 1)) { t in
            FieldSceneView(content: FieldSceneContent(course: course, grid: grid, exaggeration: exaggerate ? 2 : 1,
                                                      activeHoles: activeHoles(course)),
                           hasData: hasData,
                           members: members(course, now: t.date),
                           meshes: showMeshes ? meshes : [],
                           resetCount: resetCount)
        }
        .overlay(alignment: .topLeading) { controls(meshCount: meshes.count) }
        .overlay(alignment: .bottomLeading) { status(state, course: course) }
        .overlay(alignment: .bottomTrailing) {
            if hasData {
                Text("Elevation: USGS 3DEP").font(.caption2).padding(4)
                    .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(.white).padding(8)
            }
        }
    }

    private func controls(meshCount: Int) -> some View {
        HStack(spacing: 10) {
            if courses.count > 1 {
                Picker("Course", selection: Binding(get: { course?.id ?? "" }, set: { courseID = $0 })) {
                    ForEach(courses, id: \.id) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 180)
            }
            Button { resetCount += 1 } label: { Label("Reset view", systemImage: "camera.metering.center.weighted") }
                .help("Back to the view over the whole course")
            Toggle("2× height", isOn: $exaggerate).toggleStyle(.button)
                .help("Exaggerate the ground's height twice over; poles and markers keep their real size")
            Toggle("Meshes (\(meshCount))", isOn: $showMeshes).toggleStyle(.button)
                .disabled(meshCount == 0)
                .help(meshCount == 0 ? "No field meshes saved for this course" : "Show or hide the field meshes")
        }
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        .padding(10)
    }

    @ViewBuilder
    private func status(_ state: FieldModel.Elevation?, course: Course) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .none, .loading:
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Fetching ground heights from USGS 3DEP… flat ground until then.") }
            case let .failed(why):
                HStack(spacing: 6) {
                    Text("Couldn't fetch ground heights: \(why) Showing flat ground.").foregroundStyle(.orange)
                    Button("Retry") { Task { await field.load(course, force: true) } }
                }
            case let .ready(g, cached):
                if g.validCount == 0 {
                    Text("No elevation data here (USGS 3DEP covers the US only). Showing flat ground.").foregroundStyle(.orange)
                } else {
                    let range = g.heightRange.map { String(format: "%.1f–%.1f m", $0.lowerBound, $0.upperBound) } ?? "–"
                    let missing = g.heights.count - g.validCount
                    Text("Ground: \(g.validCount) samples every \(String(format: "%g", g.spacing)) m, \(range)"
                         + (missing > 0 ? ", \(missing) without data (filled)" : "") + (cached ? " · cached" : ""))
                }
            }
            Text("Drag to orbit · right- or ⇧-drag to pan · scroll or pinch to zoom").foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(6)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
        .foregroundStyle(.white)
        .padding(8)
    }

    private func activeHoles(_ course: Course) -> Set<Int> {
        Set(squads.filter { $0.course?.id == course.id && !$0.walkingOut }.compactMap(\.activeHole))
    }

    private func members(_ course: Course, now: Date) -> [FieldSceneMember] {
        var out: [FieldSceneMember] = []
        for (i, s) in squads.enumerated() where s.course?.id == course.id {
            let color = Self.squadColors[i % Self.squadColors.count]
            for m in s.members {
                guard let p = s.positions[m.id] else { continue }
                out.append(FieldSceneMember(id: "\(s.id)/\(m.id)", name: m.name, at: p.at, accuracy: p.accuracy, color: color,
                                            stale: now.timeIntervalSince(p.time) > SiteMap.staleAfter))
            }
        }
        return out
    }
}

/// The SceneKit view. The course and terrain are rebuilt only when what they show changes; the
/// members every update (once a second, for staleness).
struct FieldSceneView: NSViewRepresentable {
    var content: FieldSceneContent
    var hasData: Bool
    var members: [FieldSceneMember]
    var meshes: [FieldModel.Mesh]
    var resetCount: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> OrbitSceneView {
        let view = OrbitSceneView(frame: .zero)
        view.scene = CourseScene.scene()
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false   // OrbitSceneView does it, around the course
        view.scene?.rootNode.addChildNode(context.coordinator.world)
        view.pointOfView = view.cameraNode
        view.scene?.rootNode.addChildNode(view.cameraNode)
        return view
    }

    func updateNSView(_ view: OrbitSceneView, context: Context) {
        let c = context.coordinator
        let grid = content.grid, k = content.exaggeration
        let key = "\(content.course.id)/\(content.course.version)/\(grid.source)/\(grid.columns)x\(grid.rows)/\(grid.frame.originAltitude)/\(k)/\(content.activeHoles.sorted())/\(content.activeLegs.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" })/\(hasData)"
        if key != c.staticKey {
            // Back to the home view for a new course, or when its heights arrive.
            let homeKey = "\(content.course.id)/\(grid.source)"
            let rehome = c.homeKey != homeKey
            c.staticKey = key
            c.homeKey = homeKey
            c.terrain.removeFromParentNode()
            c.course.removeFromParentNode()
            c.terrain = CourseScene.terrain(grid, k: k, hasData: hasData)
            c.course = CourseScene.course(content)
            c.world.addChildNode(c.terrain)
            c.world.addChildNode(c.course)
            c.placeMeshes(grid: grid, k: k)
            view.home = OrbitSceneView.Orbit.home(over: grid, k: k)
            if rehome { view.orbit = view.home }
        }
        c.members.removeFromParentNode()
        c.members = CourseScene.members(members, grid: grid, k: k)
        c.world.addChildNode(c.members)
        c.showMeshes(meshes, grid: grid, k: k)
        if resetCount != c.resetCount {
            c.resetCount = resetCount
            view.orbit = view.home
        }
    }

    final class Coordinator {
        let world = SCNNode()
        var terrain = SCNNode(), course = SCNNode(), members = SCNNode()
        var meshNodes: [UUID: (node: SCNNode, info: FieldMeshInfo)] = [:]
        var staticKey = "", homeKey = ""
        var resetCount = 0

        /// Loads meshes not loaded yet (once each), and shows exactly the ones asked for.
        func showMeshes(_ list: [FieldModel.Mesh], grid: ElevationGrid, k: Double) {
            let wanted = Set(list.map(\.id))
            for m in list where meshNodes[m.id] == nil {
                guard let node = CourseScene.loadMesh(m.url) else { continue }
                CourseScene.place(node, info: m.info, grid: grid, k: k)
                world.addChildNode(node)
                meshNodes[m.id] = (node, m.info)
            }
            for (id, entry) in meshNodes { entry.node.isHidden = !wanted.contains(id) }
        }

        func placeMeshes(grid: ElevationGrid, k: Double) {
            for entry in meshNodes.values { CourseScene.place(entry.node, info: entry.info, grid: grid, k: k) }
        }
    }
}

/// An SCNView with a turntable camera around a target: drag to orbit, right- or shift-drag to pan,
/// scroll or pinch to zoom. (SceneKit's own camera control can roll and lose the course; this can't.)
final class OrbitSceneView: SCNView {
    struct Orbit: Equatable {
        /// The point looked at, scene coordinates.
        var target: SIMD3<Double>
        /// Radians: 0 looks north (camera to the south), increasing clockwise seen from above.
        var yaw: Double
        /// Radians above the horizon.
        var pitch: Double
        var distance: Double

        /// Over the whole grid from the south-south-west, 35° up.
        static func home(over grid: ElevationGrid, k: Double) -> Orbit {
            let e = grid.extent
            let mid = (e.southWest + e.northEast) / 2
            let size = simd_length(e.northEast - e.southWest)
            let z = grid.filled().groundZ(east: mid.x, north: mid.y)
            return Orbit(target: SceneAxes.scene(SIMD3(mid.x, mid.y, z), exaggeration: k), yaw: 0.35, pitch: 0.6,
                         distance: max(30, size * 0.7))
        }

        var cameraPosition: SIMD3<Double> {
            // Yaw 0 puts the camera on +z (south) of the target; yaw rotates it clockwise from above.
            target + distance * SIMD3(-sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch))
        }
    }

    let cameraNode: SCNNode = {
        let n = SCNNode()
        n.camera = SCNCamera()
        n.camera?.zNear = 0.2
        n.camera?.zFar = 20_000
        n.camera?.fieldOfView = 50
        return n
    }()

    var home = Orbit(target: .zero, yaw: 0, pitch: 0.6, distance: 150)
    var orbit = Orbit(target: .zero, yaw: 0, pitch: 0.6, distance: 150) { didSet { applyOrbit() } }

    func applyOrbit() {
        cameraNode.simdPosition = SIMD3<Float>(orbit.cameraPosition)
        cameraNode.simdLook(at: SIMD3<Float>(orbit.target), up: SIMD3(0, 1, 0), localFront: SIMD3(0, 0, -1))
    }

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.shift) { pan(event); return }
        orbit.yaw += Double(event.deltaX) * 0.008
        orbit.pitch = min(max(orbit.pitch + Double(event.deltaY) * 0.008, 0.05), 1.55)
    }

    override func rightMouseDragged(with event: NSEvent) { pan(event) }
    override func otherMouseDragged(with event: NSEvent) { pan(event) }

    private func pan(_ event: NSEvent) {
        // Grab the ground: dragging right moves the course right (the camera left).
        let right = SIMD3(cos(orbit.yaw), 0, sin(orbit.yaw))
        let forward = SIMD3(sin(orbit.yaw), 0, -cos(orbit.yaw))
        let scale = orbit.distance * 0.0015
        orbit.target += (-right * Double(event.deltaX) + forward * Double(event.deltaY)) * scale
    }

    override func scrollWheel(with event: NSEvent) {
        let dy = event.hasPreciseScrollingDeltas ? Double(event.scrollingDeltaY) * 0.01 : Double(event.scrollingDeltaY) * 0.1
        zoom(by: exp(-dy))
    }

    override func magnify(with event: NSEvent) { zoom(by: 1 / (1 + Double(event.magnification))) }

    private func zoom(by f: Double) {
        orbit.distance = min(max(orbit.distance * f, 3), 5_000)
    }
}
