import Foundation
import simd
import CoreGeo

// The pure geometry behind the Theater's 3D view: the terrain mesh from an elevation grid, draping
// lines and areas on it, and the one conversion from ENU to the 3D scene's axes. SceneKit itself
// stays in the app; everything here is plain numbers so it can be tested with `swift test`.
//
// The scene convention (used everywhere in the 3D view):
//   SceneKit is right-handed and y-up, so the scene is   x = east,  y = up,  z = south (−north),
//   in metres, with its origin at the elevation grid's `FieldFrame` origin and `originAltitude`.
//   Looking down from +y with north at the top of the screen, east is to the right, as on a map.
//   Vertical exaggeration k multiplies scene y only: ground height h sits at y = k·(h − originAltitude).
//   Things standing on the ground (poles, markers) keep their real height above it.
//
// Field meshes come in USD's y-up mesh coordinates; `FieldMeshInfo.toENU` already takes them to
// ENU (z up), so a mesh is placed with `SceneAxes.meshTransform`, which is `toENU`, then the shift
// between the mesh's frame and the scene's frame, then ENU → scene. Never swap axes anywhere else.

/// ENU ↔ the 3D scene's axes.
public enum SceneAxes {
    /// ENU (x east, y north, z up) to scene (x east, y up, z south), with vertical exaggeration.
    @inlinable public static func scene(_ enu: SIMD3<Double>, exaggeration k: Double = 1) -> SIMD3<Double> {
        SIMD3(enu.x, enu.z * k, -enu.y)
    }

    /// Scene back to ENU.
    @inlinable public static func enu(_ scene: SIMD3<Double>, exaggeration k: Double = 1) -> SIMD3<Double> {
        SIMD3(scene.x, -scene.z, scene.y / k)
    }

    /// The ENU → scene matrix (a rotation of −90° about east, then exaggeration on y), column-major.
    public static func matrix(exaggeration k: Double = 1) -> simd_double3x3 {
        simd_double3x3(columns: (SIMD3(1, 0, 0),    // east  → x
                                 SIMD3(0, 0, -1),   // north → −z
                                 SIMD3(0, k, 0)))   // up    → y
    }

    /// The 4×4 transform (column-major) taking a field mesh's own coordinates to scene coordinates:
    /// `toENU` into the mesh's frame, the offset from that frame to the scene's frame (both treated as
    /// parallel tangent planes, fine over a course), then ENU → scene.
    public static func meshTransform(toENU: Similarity3, meshFrame: FieldFrame, sceneFrame: FieldFrame,
                                     exaggeration k: Double = 1) -> simd_double4x4 {
        let shift = sceneFrame.enu(meshFrame.origin, altitude: meshFrame.originAltitude)
        let m = toENU.matrix
        // simd_double3x3(rows:) from the rotation's rows, times the scale.
        let r = simd_double3x3(rows: [m.0, m.1, m.2]) * toENU.scale
        let a = matrix(exaggeration: k)
        let linear = a * r
        let t = a * (toENU.translation + shift)
        return simd_double4x4(columns: (SIMD4(linear.columns.0, 0), SIMD4(linear.columns.1, 0),
                                        SIMD4(linear.columns.2, 0), SIMD4(t, 1)))
    }
}

extension ElevationGrid {
    /// A metre spacing for sampling `boundary` (with `margin`): `preferred` unless that needs more than
    /// `maxSamples` points, in which case the smallest spacing (to the next 0.5 m) that fits.
    public static func spacing(covering boundary: [GeoPoint], frame: FieldFrame, preferred: Double = 2.5,
                               maxSamples: Int = 12_000, margin: Double = 20) -> Double {
        var s = preferred
        while samplePoints(covering: boundary, frame: frame, spacing: s, margin: margin).points.count > maxSamples {
            s += 0.5
        }
        return s
    }

    /// A frame for a course: its origin at the middle of the boundary's extent.
    public static func frame(covering boundary: [GeoPoint]) -> FieldFrame {
        guard let first = boundary.first else { return FieldFrame(origin: GeoPoint(latitude: 0, longitude: 0)) }
        let lat = boundary.map(\.latitude), lon = boundary.map(\.longitude)
        let mid = GeoPoint(latitude: (lat.min()! + lat.max()!) / 2, longitude: (lon.min()! + lon.max()!) / 2)
        return FieldFrame(origin: boundary.count > 1 ? mid : first)
    }

    /// Flat ground over `boundary`, at the frame's origin altitude: what the view shows with no heights.
    public static func flat(covering boundary: [GeoPoint], frame: FieldFrame, spacing: Double = 10,
                            margin: Double = 20) -> ElevationGrid {
        let s = samplePoints(covering: boundary, frame: frame, spacing: spacing, margin: margin)
        return ElevationGrid(frame: frame, southWest: s.southWest, spacing: spacing, columns: s.columns, rows: s.rows,
                             heights: Array(repeating: frame.originAltitude, count: s.columns * s.rows), source: "flat")
    }

    /// How many samples have a height.
    public var validCount: Int { heights.reduce(0) { $1.isNaN ? $0 : $0 + 1 } }

    /// The lowest and highest heights, nil when there are none.
    public var heightRange: ClosedRange<Double>? {
        let v = heights.filter { !$0.isNaN }
        guard let lo = v.min(), let hi = v.max() else { return nil }
        return lo...hi
    }

    /// The grid with every NaN replaced: by the mean of the heights it has, or by the frame's origin
    /// altitude when it has none (flat ground).
    public func filled() -> ElevationGrid {
        let valid = heights.filter { !$0.isNaN }
        let fill = valid.isEmpty ? frame.originAltitude : valid.reduce(0, +) / Double(valid.count)
        var g = self
        g.heights = heights.map { $0.isNaN ? fill : $0 }
        return g
    }

    /// The grid's ENU extent: south-west and north-east corners.
    public var extent: (southWest: SIMD2<Double>, northEast: SIMD2<Double>) {
        (southWest, southWest + SIMD2(Double(columns - 1), Double(rows - 1)) * spacing)
    }

    /// Bilinear height with east/north clamped into the grid, so draping never falls off its edge.
    /// NaN only if the grid has NaN there (use `filled()` first).
    public func clampedHeight(east: Double, north: Double) -> Double {
        let e = extent
        let x = min(max(east, e.southWest.x), e.northEast.x), y = min(max(north, e.southWest.y), e.northEast.y)
        return height(east: x, north: y) ?? .nan
    }

    /// Ground at an ENU point, as an ENU z (metres above the frame's origin altitude).
    public func groundZ(east: Double, north: Double) -> Double {
        clampedHeight(east: east, north: north) - frame.originAltitude
    }

    /// The highest ground within `radius` of an ENU point (the point and eight around it), as an ENU z:
    /// for draping an area whose vertices are about `radius` apart over the terrain without the
    /// terrain's own vertices poking through between them.
    public func groundZ(east: Double, north: Double, within radius: Double) -> Double {
        var z = groundZ(east: east, north: north)
        for i in 0..<8 {
            let a = Double(i) * .pi / 4
            z = max(z, groundZ(east: east + radius * cos(a), north: north + radius * sin(a)))
        }
        return z
    }

    /// JSON for the cache. NaN (no data) is written as the string "nan", which plain JSON can't hold.
    public func encodedJSON() throws -> Data {
        let e = JSONEncoder()
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try e.encode(self)
    }

    public static func decodeJSON(_ data: Data) throws -> ElevationGrid {
        let d = JSONDecoder()
        d.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return try d.decode(ElevationGrid.self, from: data)
    }

    /// True when the grid reaches every point given (ENU in its own frame), e.g. a cached grid still
    /// covering an edited course.
    public func covers(_ points: [GeoPoint]) -> Bool {
        let e = extent
        return points.allSatisfy {
            let v = frame.enu($0)
            return v.x >= e.southWest.x - 1e-6 && v.x <= e.northEast.x + 1e-6 && v.y >= e.southWest.y - 1e-6 && v.y <= e.northEast.y + 1e-6
        }
    }
}

/// A terrain surface ready for a renderer: one vertex per grid sample, in scene coordinates.
public struct TerrainMesh: Equatable, Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    /// 0 at the lowest sample, 1 at the highest (0.5 everywhere on flat ground): for shading by height.
    public var heightFraction: [Float]
    /// Triangles, counter-clockwise seen from above (SceneKit's front face).
    public var indices: [UInt32]

    /// Builds the surface from `grid` (NaN filled first), exaggerating heights by `exaggeration`.
    public init(grid input: ElevationGrid, exaggeration k: Double = 1) {
        let grid = input.filled()
        let cols = grid.columns, rows = grid.rows
        let range = grid.heightRange ?? grid.frame.originAltitude...grid.frame.originAltitude
        let span = range.upperBound - range.lowerBound
        positions = []; normals = []; heightFraction = []; indices = []
        positions.reserveCapacity(cols * rows)
        for r in 0..<rows {
            for c in 0..<cols {
                let en = grid.position(column: c, row: r)
                let z = grid.height(column: c, row: r) - grid.frame.originAltitude
                let p = SceneAxes.scene(SIMD3(en.x, en.y, z), exaggeration: k)
                positions.append(SIMD3<Float>(p))
                heightFraction.append(span > 1e-9 ? Float((grid.height(column: c, row: r) - range.lowerBound) / span) : 0.5)
            }
        }
        // Normals from central differences of the (exaggerated) height field. In ENU the up normal of
        // z = f(x, y) is (−fx, −fy, 1); in scene axes that is (−fx, 1, fy).
        for r in 0..<rows {
            for c in 0..<cols {
                let c0 = max(c - 1, 0), c1 = min(c + 1, cols - 1), r0 = max(r - 1, 0), r1 = min(r + 1, rows - 1)
                let fx = k * (grid.height(column: c1, row: r) - grid.height(column: c0, row: r)) / (Double(c1 - c0) * grid.spacing)
                let fy = k * (grid.height(column: c, row: r1) - grid.height(column: c, row: r0)) / (Double(r1 - r0) * grid.spacing)
                normals.append(SIMD3<Float>(simd_normalize(SIMD3(-fx, 1, fy))))
            }
        }
        indices.reserveCapacity((cols - 1) * (rows - 1) * 6)
        for r in 0..<(rows - 1) {
            for c in 0..<(cols - 1) {
                let sw = UInt32(r * cols + c), se = sw + 1, nw = sw + UInt32(cols), ne = nw + 1
                // South-west, south-east, north-east is counter-clockwise on a map (east right, north up).
                indices += [sw, se, ne, sw, ne, nw]
            }
        }
    }
}

/// Lines and areas laid on the ground.
public enum Drape {
    /// `path` (ENU east/north) densified to at most `step` metres between points, each at the ground
    /// height under it (ENU z). `closed` adds the segment back to the start.
    public static func line(_ path: [SIMD2<Double>], on grid: ElevationGrid, step: Double = 1,
                            closed: Bool = false) -> [SIMD3<Double>] {
        guard !path.isEmpty else { return [] }
        let filled = grid.filled()
        var pts = path
        if closed, let first = path.first, path.count > 2 { pts.append(first) }
        var out: [SIMD3<Double>] = []
        func add(_ p: SIMD2<Double>) { out.append(SIMD3(p.x, p.y, filled.groundZ(east: p.x, north: p.y))) }
        add(pts[0])
        for (a, b) in zip(pts, pts.dropFirst()) {
            let n = max(1, Int((simd_length(b - a) / step).rounded(.up)))
            for i in 1...n { add(a + (b - a) * (Double(i) / Double(n))) }
        }
        return out
    }

    /// A circle of `radius` around `centre` (ENU), `segments` points, not repeating the first.
    public static func circle(centre: SIMD2<Double>, radius: Double, segments: Int = 48) -> [SIMD2<Double>] {
        (0..<segments).map {
            let a = Double($0) / Double(segments) * 2 * .pi
            return centre + SIMD2(cos(a), sin(a)) * radius
        }
    }

    /// A wedge from `apex` toward `toward` (ENU), ± `halfAngle` degrees, out to `range` metres, as a
    /// triangulated surface: rings every `radialStep` metres and spokes every `angleStep` degrees, so
    /// it can follow the ground. Points are ENU east/north; `indices` are counter-clockwise from above.
    public static func wedge(apex: SIMD2<Double>, toward: SIMD2<Double>, halfAngle: Double, range: Double,
                             radialStep: Double = 4, angleStep: Double = 3) -> (points: [SIMD2<Double>], indices: [UInt32]) {
        let d = toward - apex
        // Compass bearing (clockwise from north) of the centre line.
        let centre = atan2(d.x, d.y)
        let spokes = max(1, Int((2 * halfAngle / angleStep).rounded(.up)))
        let rings = max(1, Int((range / radialStep).rounded(.up)))
        var points = [apex]
        for ring in 1...rings {
            let r = range * Double(ring) / Double(rings)
            for s in 0...spokes {
                // From the left edge (bearing − half) clockwise to the right edge.
                let b = centre + (-halfAngle + 2 * halfAngle * Double(s) / Double(spokes)) * .pi / 180
                points.append(apex + SIMD2(sin(b), cos(b)) * r)
            }
        }
        func idx(_ ring: Int, _ s: Int) -> UInt32 { UInt32(1 + (ring - 1) * (spokes + 1) + s) }
        var indices: [UInt32] = []
        // Bearing increases clockwise seen from above, so (apex, s+1, s) is counter-clockwise.
        for s in 0..<spokes { indices += [0, idx(1, s + 1), idx(1, s)] }
        if rings > 1 {
            for ring in 1..<rings {
                for s in 0..<spokes {
                    let a = idx(ring, s), b = idx(ring, s + 1), c = idx(ring + 1, s + 1), e = idx(ring + 1, s)
                    indices += [a, b, c, a, c, e]
                }
            }
        }
        return (points, indices)
    }
}
