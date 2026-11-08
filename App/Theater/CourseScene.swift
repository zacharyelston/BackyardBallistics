import AppKit
import SceneKit
import simd
import CoreGeo
import SafetyKit
import CourseKit
import FieldKit

// Builds the SceneKit nodes for the Theater's 3D view. The geometry itself (terrain, draping,
// wedges, the axes) is FieldKit's and unit-tested there; this file only turns it into nodes.
//
// Scene convention (FieldKit/FieldScene.swift, `SceneAxes`): x east, y up, z south, metres, origin at
// the elevation grid's frame origin and origin altitude. With exaggeration k the ground is at
// y = k·(ground ENU z); poles, markers and lifts above the ground keep their real size.

/// A member to draw.
struct FieldSceneMember {
    var id: String
    var name: String
    var at: GeoPoint
    var accuracy: Double
    var color: NSColor
    var stale: Bool
}

/// Everything the course part of the scene depends on.
struct FieldSceneContent {
    var course: Course
    /// Heights; `ElevationGrid.flat` while there are none.
    var grid: ElevationGrid
    var exaggeration: Double
    /// Holes in play (their fans drawn strong).
    var activeHoles: Set<Int>
    /// On active holes with layups, the leg in play (`Hole.targets` index it aims at). A hole not
    /// listed is on its flag leg.
    var activeLegs: [Int: Int] = [:]
}

enum CourseScene {
    /// Lift above the ground for draped overlays, metres, so they don't flicker into the terrain.
    static let lift = 0.12

    // MARK: Coordinates

    /// Scene position of ENU east/north on the ground, `above` metres higher (not exaggerated).
    static func ground(_ en: SIMD2<Double>, grid: ElevationGrid, k: Double, above: Double = 0) -> SCNVector3 {
        let z = grid.filled().groundZ(east: en.x, north: en.y)
        return vec(SceneAxes.scene(SIMD3(en.x, en.y, z), exaggeration: k) + SIMD3(0, above, 0))
    }

    static func vec(_ v: SIMD3<Double>) -> SCNVector3 { SCNVector3(CGFloat(v.x), CGFloat(v.y), CGFloat(v.z)) }

    static func en(_ p: GeoPoint, _ grid: ElevationGrid) -> SIMD2<Double> {
        let v = grid.frame.enu(p)
        return SIMD2(v.x, v.y)
    }

    // MARK: Terrain

    /// The ground: the grid's surface, shaded from green (low) through tan to pale (high).
    static func terrain(_ grid: ElevationGrid, k: Double, hasData: Bool) -> SCNNode {
        let mesh = TerrainMesh(grid: grid, exaggeration: k)
        let colors: [SIMD4<Float>] = mesh.heightFraction.map { hasData ? ramp($0) : SIMD4(0.32, 0.4, 0.3, 1) }
        let geometry = SCNGeometry(sources: [source(mesh.positions, .vertex), source(mesh.normals, .normal),
                                             colorSource(colors)],
                                   elements: [SCNGeometryElement(indices: mesh.indices, primitiveType: .triangles)])
        let m = SCNMaterial()
        m.diffuse.contents = NSColor.white   // multiplied by the vertex colours
        m.lightingModel = .lambert
        geometry.materials = [m]
        let node = SCNNode(geometry: geometry)
        node.name = "terrain"
        return node
    }

    static func ramp(_ t: Float) -> SIMD4<Float> {
        let stops: [SIMD3<Float>] = [SIMD3(0.20, 0.38, 0.17), SIMD3(0.42, 0.52, 0.25), SIMD3(0.62, 0.55, 0.36), SIMD3(0.85, 0.82, 0.74)]
        let x = min(max(t, 0), 1) * Float(stops.count - 1)
        let i = min(Int(x), stops.count - 2)
        let c = simd_mix(stops[i], stops[i + 1], SIMD3(repeating: x - Float(i)))
        return SIMD4(c, 1)
    }

    private static func source(_ v: [SIMD3<Float>], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: semantic, vectorCount: v.count, usesFloatComponents: true,
                                 componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0,
                                 dataStride: MemoryLayout<SIMD3<Float>>.stride)
    }

    private static func colorSource(_ v: [SIMD4<Float>]) -> SCNGeometrySource {
        let data = v.withUnsafeBufferPointer { Data(buffer: $0) }
        return SCNGeometrySource(data: data, semantic: .color, vectorCount: v.count, usesFloatComponents: true,
                                 componentsPerVector: 4, bytesPerComponent: 4, dataOffset: 0,
                                 dataStride: MemoryLayout<SIMD4<Float>>.stride)
    }

    // MARK: Draped shapes

    /// A flat strip `width` metres wide along a draped ENU path, `above` the ground: a line that reads
    /// at any distance (SceneKit's line primitive is one pixel).
    static func ribbon(_ path: [SIMD3<Double>], width: Double, above: Double = lift, k: Double, color: NSColor) -> SCNNode {
        guard path.count >= 2 else { return SCNNode() }
        var verts: [SIMD3<Float>] = [], normals: [SIMD3<Float>] = [], idx: [UInt32] = []
        for (i, p) in path.enumerated() {
            let a = path[max(i - 1, 0)], b = path[min(i + 1, path.count - 1)]
            var dir = SIMD2(b.x - a.x, b.y - a.y)
            let len = simd_length(dir)
            dir = len > 1e-9 ? dir / len : SIMD2(1, 0)
            let side = SIMD2(-dir.y, dir.x) * (width / 2)   // left of travel, ENU
            for s in [1.0, -1.0] {
                let q = SceneAxes.scene(SIMD3(p.x + side.x * s, p.y + side.y * s, p.z), exaggeration: k) + SIMD3(0, above, 0)
                verts.append(SIMD3<Float>(q))
                normals.append(SIMD3(0, 1, 0))
            }
            if i > 0 {
                let l0 = UInt32(2 * (i - 1)), r0 = l0 + 1, l1 = l0 + 2, r1 = l0 + 3
                idx += [l0, r0, r1, l0, r1, l1]
            }
        }
        let g = SCNGeometry(sources: [source(verts, .vertex), source(normals, .normal)],
                            elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
        g.materials = [overlayMaterial(color)]
        return SCNNode(geometry: g)
    }

    /// A draped triangulated area (ENU east/north points about one grid spacing apart), e.g. a safety
    /// fan. Each vertex sits on the highest ground within a grid spacing, so terrain between the
    /// area's vertices can't poke through it.
    static func area(_ points: [SIMD2<Double>], indices: [UInt32], grid: ElevationGrid, above: Double, k: Double,
                     color: NSColor) -> SCNNode {
        let filled = grid.filled()
        let verts: [SIMD3<Float>] = points.map {
            let z = filled.groundZ(east: $0.x, north: $0.y, within: grid.spacing)
            return SIMD3<Float>(SceneAxes.scene(SIMD3($0.x, $0.y, z), exaggeration: k) + SIMD3(0, above, 0))
        }
        let g = SCNGeometry(sources: [source(verts, .vertex), source(Array(repeating: SIMD3(0, 1, 0), count: verts.count), .normal)],
                            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        g.materials = [overlayMaterial(color)]
        return SCNNode(geometry: g)
    }

    static func overlayMaterial(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .constant
        m.isDoubleSided = true
        m.transparency = color.alphaComponent
        m.diffuse.contents = color.withAlphaComponent(1)
        m.blendMode = .alpha
        m.writesToDepthBuffer = color.alphaComponent >= 1
        return m
    }

    // MARK: The course

    static func course(_ c: FieldSceneContent) -> SCNNode {
        let root = SCNNode()
        root.name = "course"
        let grid = c.grid, k = c.exaggeration
        let limits = Safety.limits

        // Boundary, draped.
        let boundary = c.course.boundary.vertices.map { en($0, grid) }
        root.addChildNode(ribbon(Drape.line(boundary, on: grid, step: 1, closed: true), width: 0.35, k: k, color: .white))

        for hole in c.course.holes {
            let active = c.activeHoles.contains(hole.number)
            let flag = en(hole.flag.position, grid)

            let targets = hole.targets
            let activeLeg = min(c.activeLegs[hole.number] ?? targets.count - 1, targets.count - 1)

            // Each leg: every firing point toward the first target (leg 0), then each layup toward
            // the next target. Safety fans first (lowest), one per leg; the leg in play drawn strong.
            let legs: [(index: Int, from: GeoPoint, to: GeoPoint)] =
                hole.firingPoints.map { (index: 0, from: $0, to: targets[0].position) }
                + hole.layups.enumerated().map { (k, l) in (index: k + 1, from: l.position, to: targets[k + 1].position) }
            for leg in legs {
                let apex = en(leg.from, grid), aim = en(leg.to, grid)
                let strong = active && leg.index == activeLeg
                // Vertices about one grid spacing apart, so the wedge follows the ground as closely as
                // the terrain does; lifted a little more with exaggeration, which sharpens the bumps.
                let angleStep = max(0.75, grid.spacing / limits.fanRange * 180 / .pi)
                let w = Drape.wedge(apex: apex, toward: aim, halfAngle: limits.fanHalfAngle, range: limits.fanRange,
                                    radialStep: grid.spacing, angleStep: angleStep)
                let fan = area(w.points, indices: w.indices, grid: grid, above: 0.1 * k + Double(hole.number) * 0.01, k: k,
                               color: NSColor.systemRed.withAlphaComponent(strong ? 0.32 : 0.07))
                fan.renderingOrder = strong ? 2 : 1
                root.addChildNode(fan)
                if strong {
                    // Its outline: the two edges and the arc (the wedge's outer ring).
                    let spokes = max(1, Int((2 * limits.fanHalfAngle / angleStep).rounded(.up)))
                    let arc = Array(w.points.suffix(spokes + 1))
                    root.addChildNode(ribbon(Drape.line([apex] + arc + [apex], on: grid, step: 1), width: 0.3,
                                             above: 0.25 * k, k: k, color: .systemRed))
                }
                // The leg's line, start to target.
                root.addChildNode(ribbon(Drape.line([apex, aim], on: grid, step: 1), width: strong ? 0.12 : 0.08,
                                         above: lift * 1.2, k: k,
                                         color: NSColor.white.withAlphaComponent(strong ? 0.85 : 0.6)))
            }

            // Firing points: white pyramids.
            for (i, fp) in hole.firingPoints.enumerated() {
                let apex = en(fp, grid)
                let marker = SCNNode(geometry: SCNPyramid(width: 0.8, height: 0.9, length: 0.8))
                marker.geometry?.firstMaterial = solid(.white)
                marker.position = ground(apex, grid: grid, k: k)
                root.addChildNode(marker)
                root.addChildNode(label("\(hole.number)·\(i + 1)", at: ground(apex, grid: grid, k: k, above: 1.8), size: 1.4))
            }

            // Layup marker poles: their real height, striped orange and white, no ring.
            for (k2, layup) in hole.layups.enumerated() {
                let p = en(layup.position, grid)
                root.addChildNode(markerPole(height: layup.poleHeightM, at: ground(p, grid: grid, k: k),
                                             highlighted: active && activeLeg == k2))
                root.addChildNode(label("Layup \(k2 + 1)", at: ground(p, grid: grid, k: k, above: layup.poleHeightM + 0.8), size: 1.6))
            }

            // The in-radius ring.
            root.addChildNode(ribbon(Drape.line(Drape.circle(centre: flag, radius: hole.flag.inRadiusM), on: grid, step: 0.25, closed: true),
                                     width: 0.12, above: lift * 2, k: k, color: .systemGreen))

            // The pole, its real height, with an orange band at the top.
            let pole = SCNNode()
            pole.position = ground(flag, grid: grid, k: k)
            let h = hole.flag.poleHeightM, band = min(0.3, h / 4)
            let shaft = SCNNode(geometry: SCNCylinder(radius: 0.04, height: CGFloat(h - band)))
            shaft.geometry?.firstMaterial = solid(.white)
            shaft.position = SCNVector3(0, CGFloat((h - band) / 2), 0)
            let top = SCNNode(geometry: SCNCylinder(radius: 0.06, height: CGFloat(band)))
            top.geometry?.firstMaterial = solid(.systemOrange)
            top.position = SCNVector3(0, CGFloat(h - band / 2), 0)
            pole.addChildNode(shaft)
            pole.addChildNode(top)
            root.addChildNode(pole)
            root.addChildNode(label("Hole \(hole.number)", at: ground(flag, grid: grid, k: k, above: h + 0.8), size: 2))
        }
        return root
    }

    /// A layup's marker pole: alternating orange and white bands about 0.5 m long, yellow tip when
    /// it's the leg's target.
    static func markerPole(height h: Double, at position: SCNVector3, highlighted: Bool) -> SCNNode {
        let pole = SCNNode()
        pole.position = position
        let bands = max(2, Int((h / 0.5).rounded()))
        let bandH = h / Double(bands)
        for b in 0..<bands {
            let seg = SCNNode(geometry: SCNCylinder(radius: 0.045, height: CGFloat(bandH)))
            let top = b == bands - 1
            seg.geometry?.firstMaterial = solid(top && highlighted ? .systemYellow : (b % 2 == 0 ? .systemOrange : .white))
            seg.position = SCNVector3(0, CGFloat(bandH * (Double(b) + 0.5)), 0)
            pole.addChildNode(seg)
        }
        return pole
    }

    // MARK: Members

    static func members(_ list: [FieldSceneMember], grid: ElevationGrid, k: Double) -> SCNNode {
        let root = SCNNode()
        root.name = "members"
        for m in list {
            let p = en(m.at, grid)
            let color = m.stale ? NSColor.systemGray : m.color
            let node = SCNNode()
            node.position = ground(p, grid: grid, k: k)
            let stalk = SCNNode(geometry: SCNCylinder(radius: 0.05, height: 1.5))
            stalk.geometry?.firstMaterial = solid(color)
            stalk.position = SCNVector3(0, 0.75, 0)
            let head = SCNNode(geometry: SCNSphere(radius: 0.45))
            head.geometry?.firstMaterial = solid(color)
            head.position = SCNVector3(0, 1.8, 0)
            node.addChildNode(stalk)
            node.addChildNode(head)
            root.addChildNode(node)
            // GPS accuracy as a draped ring.
            let ring = Drape.line(Drape.circle(centre: p, radius: max(1, m.accuracy), segments: 40), on: grid, step: 0.5, closed: true)
            root.addChildNode(ribbon(ring, width: 0.15, above: lift * 2.5, k: k, color: color.withAlphaComponent(0.7)))
            root.addChildNode(label(m.stale ? "\(m.name) (stale)" : m.name, at: ground(p, grid: grid, k: k, above: 2.8), size: 1.6))
        }
        return root
    }

    // MARK: Field meshes

    /// A USDZ field mesh under a node placed with its `toENU`: mesh coordinates are used exactly as
    /// stored (SceneKit doesn't convert the up axis or units unless asked), so `toENU` applies as written.
    static func loadMesh(_ url: URL) -> SCNNode? {
        guard let scene = try? SCNScene(url: url, options: [.convertToYUp: false]) else { return nil }
        let node = SCNNode()
        for child in scene.rootNode.childNodes { node.addChildNode(child) }
        return node
    }

    static func place(_ node: SCNNode, info: FieldMeshInfo, grid: ElevationGrid, k: Double) {
        let m = SceneAxes.meshTransform(toENU: info.toENU, meshFrame: info.frame, sceneFrame: grid.frame, exaggeration: k)
        node.simdTransform = simd_float4x4(columns: (SIMD4<Float>(m.columns.0), SIMD4<Float>(m.columns.1),
                                                     SIMD4<Float>(m.columns.2), SIMD4<Float>(m.columns.3)))
    }

    // MARK: Scene, lights, camera

    static func scene() -> SCNScene {
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.55, green: 0.68, blue: 0.82, alpha: 1)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 450
        scene.rootNode.addChildNode(ambient)
        let sun = SCNNode()
        sun.light = SCNLight()
        sun.light?.type = .directional
        sun.light?.intensity = 900
        // From the south-west, 40° up: low enough to show relief.
        sun.simdEulerAngles = SIMD3(-40 * .pi / 180, -135 * .pi / 180, 0)
        scene.rootNode.addChildNode(sun)
        return scene
    }

    // MARK: Helpers

    static func solid(_ color: NSColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .lambert
        return m
    }

    /// A text label that always faces the camera, `size` metres tall.
    static func label(_ text: String, at p: SCNVector3, size: CGFloat) -> SCNNode {
        let t = SCNText(string: text, extrusionDepth: 0)
        t.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        t.flatness = 0.2
        t.firstMaterial = {
            let m = SCNMaterial()
            m.diffuse.contents = NSColor.white
            m.lightingModel = .constant
            m.isDoubleSided = true
            return m
        }()
        let inner = SCNNode(geometry: t)
        let (lo, hi) = t.boundingBox
        inner.pivot = SCNMatrix4MakeTranslation((lo.x + hi.x) / 2, lo.y, 0)
        let scale = size / 10
        inner.scale = SCNVector3(scale, scale, scale)
        let node = SCNNode()
        node.position = p
        node.addChildNode(inner)
        let billboard = SCNBillboardConstraint()
        billboard.freeAxes = .all
        node.constraints = [billboard]
        return node
    }
}
