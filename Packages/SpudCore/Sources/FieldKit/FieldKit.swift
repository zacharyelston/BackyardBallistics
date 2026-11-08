import Foundation
import CoreGeo

// FieldKit: the field in 3D (docs/GROUP_PLAY.md, The field map; docs/THEATER_MODE.md, T4).
//
// Everything here is in one local frame per course: ENU metres from an origin point, x east,
// y north, z up. A photo reconstruction comes out in its own arbitrary frame; `Similarity3.fit`
// pins it to ENU from the cameras' GPS positions, and `FieldMeshInfo` records the result next to
// the mesh. `ElevationGrid` holds bare-earth heights (for example from USGS 3DEP).
//
// The field model is a picture, never an input to firing: nothing here feeds SafetyKit.

/// A local east-north-up frame on the course.
public struct FieldFrame: Codable, Equatable, Sendable {
    public var origin: GeoPoint
    /// Height of the origin, metres (the same datum as the heights used with this frame).
    public var originAltitude: Double

    public init(origin: GeoPoint, originAltitude: Double = 0) {
        self.origin = origin
        self.originAltitude = originAltitude
    }

    /// ENU metres for a GPS point and altitude.
    public func enu(_ p: GeoPoint, altitude: Double? = nil) -> SIMD3<Double> {
        let en = Geo.eastNorth(of: p, from: origin)
        return SIMD3(en.east, en.north, (altitude ?? originAltitude) - originAltitude)
    }

    /// The GPS point and altitude for ENU metres.
    public func geo(_ v: SIMD3<Double>) -> (point: GeoPoint, altitude: Double) {
        (Geo.offset(origin, east: v.x, north: v.y), originAltitude + v.z)
    }
}

/// x ↦ s·R·x + t. Rotation stored as a unit quaternion (x, y, z, w).
public struct Similarity3: Codable, Equatable, Sendable {
    public var scale: Double
    public var rotation: [Double]
    public var translation: SIMD3<Double>

    public static let identity = Similarity3(scale: 1, rotation: [0, 0, 0, 1], translation: .zero)

    public init(scale: Double, rotation: [Double], translation: SIMD3<Double>) {
        self.scale = scale
        self.rotation = rotation
        self.translation = translation
    }

    public init(scale: Double, axis: SIMD3<Double>, angle: Double, translation: SIMD3<Double>) {
        let a = axis / (axis * axis).sum().squareRoot()
        let h = angle / 2
        self.init(scale: scale, rotation: [a.x * sin(h), a.y * sin(h), a.z * sin(h), cos(h)], translation: translation)
    }

    /// Rows of the rotation matrix.
    public var matrix: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>) {
        let x = rotation[0], y = rotation[1], z = rotation[2], w = rotation[3]
        return (SIMD3(1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w)),
                SIMD3(2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w)),
                SIMD3(2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y)))
    }

    public func rotate(_ v: SIMD3<Double>) -> SIMD3<Double> {
        let m = matrix
        return SIMD3((m.0 * v).sum(), (m.1 * v).sum(), (m.2 * v).sum())
    }

    public func apply(_ v: SIMD3<Double>) -> SIMD3<Double> { scale * rotate(v) + translation }

    /// The best scale, rotation and translation taking `source` points onto `target` points in the
    /// least-squares sense (Horn's quaternion method), with optional per-point weights.
    /// Needs at least three points that aren't all on one line.
    public static func fit(from source: [SIMD3<Double>], to target: [SIMD3<Double>],
                           weights: [Double]? = nil) -> Similarity3? {
        let n = source.count
        guard n >= 3, target.count == n else { return nil }
        let w = weights ?? Array(repeating: 1, count: n)
        let W = w.reduce(0, +)
        guard W > 0 else { return nil }
        var ca = SIMD3<Double>.zero, cb = SIMD3<Double>.zero
        for i in 0..<n { ca += w[i] * source[i]; cb += w[i] * target[i] }
        ca /= W; cb /= W

        // Cross-covariance M = Σ w a' b'ᵀ.
        var M = [[Double]](repeating: [0, 0, 0], count: 3)
        var sa = 0.0
        for i in 0..<n {
            let a = source[i] - ca, b = target[i] - cb
            sa += w[i] * (a * a).sum()
            for r in 0..<3 { for c in 0..<3 { M[r][c] += w[i] * a[r] * b[c] } }
        }
        guard sa > 1e-12 else { return nil }
        let (Sxx, Sxy, Sxz) = (M[0][0], M[0][1], M[0][2])
        let (Syx, Syy, Syz) = (M[1][0], M[1][1], M[1][2])
        let (Szx, Szy, Szz) = (M[2][0], M[2][1], M[2][2])
        // Horn's symmetric 4×4; its top eigenvector is the rotation quaternion (w, x, y, z).
        let N: [[Double]] = [
            [Sxx + Syy + Szz, Syz - Szy, Szx - Sxz, Sxy - Syx],
            [Syz - Szy, Sxx - Syy - Szz, Sxy + Syx, Szx + Sxz],
            [Szx - Sxz, Sxy + Syx, -Sxx + Syy - Szz, Syz + Szy],
            [Sxy - Syx, Szx + Sxz, Syz + Szy, -Sxx - Syy + Szz],
        ]
        let (values, vectors) = jacobiEigen(N)
        guard let top = values.indices.max(by: { values[$0] < values[$1] }) else { return nil }
        let q = vectors.map { $0[top] }   // column `top`
        let norm = (q.map { $0 * $0 }.reduce(0, +)).squareRoot()
        guard norm > 0 else { return nil }
        var result = Similarity3(scale: 1, rotation: [q[1] / norm, q[2] / norm, q[3] / norm, q[0] / norm], translation: .zero)

        // Scale: Σ w b'·(R a') / Σ w |a'|².
        var num = 0.0
        for i in 0..<n { num += w[i] * ((target[i] - cb) * result.rotate(source[i] - ca)).sum() }
        result.scale = num / sa
        guard result.scale > 0 else { return nil }
        result.translation = cb - result.scale * result.rotate(ca)
        return result
    }

    /// Root-mean-square distance between the transformed source points and the targets.
    public func rms(from source: [SIMD3<Double>], to target: [SIMD3<Double>]) -> Double {
        guard !source.isEmpty else { return 0 }
        let s = zip(source, target).map { a, b -> Double in let d = apply(a) - b; return (d * d).sum() }.reduce(0, +)
        return (s / Double(source.count)).squareRoot()
    }
}

/// Eigen-decomposition of a small symmetric matrix by cyclic Jacobi rotations.
/// Returns the eigenvalues and a matrix whose columns are the eigenvectors.
func jacobiEigen(_ input: [[Double]]) -> ([Double], [[Double]]) {
    let n = input.count
    var a = input
    var v = (0..<n).map { i in (0..<n).map { $0 == i ? 1.0 : 0.0 } }
    for _ in 0..<100 {
        var off = 0.0
        for p in 0..<n { for q in (p + 1)..<n { off += a[p][q] * a[p][q] } }
        if off < 1e-22 { break }
        for p in 0..<n {
            for q in (p + 1)..<n where abs(a[p][q]) > 1e-300 {
                let theta = (a[q][q] - a[p][p]) / (2 * a[p][q])
                let t = (theta >= 0 ? 1 : -1) / (abs(theta) + (theta * theta + 1).squareRoot())
                let c = 1 / (t * t + 1).squareRoot(), s = t * c
                for k in 0..<n {
                    let akp = a[k][p], akq = a[k][q]
                    a[k][p] = c * akp - s * akq
                    a[k][q] = s * akp + c * akq
                }
                for k in 0..<n {
                    let apk = a[p][k], aqk = a[q][k]
                    a[p][k] = c * apk - s * aqk
                    a[q][k] = s * apk + c * aqk
                }
                for k in 0..<n {
                    let vkp = v[k][p], vkq = v[k][q]
                    v[k][p] = c * vkp - s * vkq
                    v[k][q] = s * vkp + c * vkq
                }
            }
        }
    }
    return ((0..<n).map { a[$0][$0] }, v)
}

/// A georeferenced field mesh, stored as `mesh.json` next to its `mesh.usdz`.
public struct FieldMeshInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var courseID: String
    public var name: String
    public var createdAt: Date
    public var frame: FieldFrame
    /// Mesh coordinates (as stored in the USDZ, metres, y up as USD has it) to ENU metres.
    public var toENU: Similarity3
    public var imageCount: Int
    /// RMS of the camera positions against their GPS, metres: how well the mesh is placed.
    public var residualRMS: Double
    /// The mesh file's name in the same folder.
    public var meshFile: String

    public init(id: UUID = UUID(), courseID: String, name: String, createdAt: Date = Date(), frame: FieldFrame,
                toENU: Similarity3, imageCount: Int, residualRMS: Double, meshFile: String = "mesh.usdz") {
        self.id = id
        self.courseID = courseID
        self.name = name
        self.createdAt = createdAt
        self.frame = frame
        self.toENU = toENU
        self.imageCount = imageCount
        self.residualRMS = residualRMS
        self.meshFile = meshFile
    }
}

/// Where field data lives on the Theater host: `<root>/<courseID>/meshes/<meshID>/{mesh.json, mesh.usdz}`
/// and `<root>/<courseID>/elevation.json`.
public struct FieldStore: Sendable {
    public var root: URL
    public init(root: URL) { self.root = root }

    /// `~/Library/Application Support/SpudTheater/Fields`.
    public static var defaultRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SpudTheater/Fields", isDirectory: true)
    }

    public func courseDirectory(_ courseID: String) -> URL {
        root.appendingPathComponent(courseID, isDirectory: true)
    }

    public func meshDirectory(courseID: String, id: UUID) -> URL {
        courseDirectory(courseID).appendingPathComponent("meshes/\(id.uuidString)", isDirectory: true)
    }

    public func elevationURL(courseID: String) -> URL {
        courseDirectory(courseID).appendingPathComponent("elevation.json")
    }

    /// Every mesh saved for a course, newest first.
    public func meshes(courseID: String) -> [(info: FieldMeshInfo, mesh: URL)] {
        let dir = courseDirectory(courseID).appendingPathComponent("meshes", isDirectory: true)
        let folders = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return folders.compactMap { f in
            guard let data = try? Data(contentsOf: f.appendingPathComponent("mesh.json")),
                  let info = try? decoder.decode(FieldMeshInfo.self, from: data) else { return nil }
            return (info, f.appendingPathComponent(info.meshFile))
        }
        .sorted { $0.info.createdAt > $1.info.createdAt }
    }

    public func save(_ info: FieldMeshInfo) throws -> URL {
        let dir = meshDirectory(courseID: info.courseID, id: info.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(info).write(to: dir.appendingPathComponent("mesh.json"), options: .atomic)
        return dir
    }
}

/// Bare-earth heights on a regular grid in a field frame: row 0 is the south edge, column 0 the west.
public struct ElevationGrid: Codable, Equatable, Sendable {
    public var frame: FieldFrame
    /// ENU of the south-west sample.
    public var southWest: SIMD2<Double>
    /// Metres between samples, east and north.
    public var spacing: Double
    public var columns: Int
    public var rows: Int
    /// Heights in metres, row by row from the south; NaN where the source had no data.
    public var heights: [Double]
    /// Where the heights came from, for the map's credits.
    public var source: String

    public init(frame: FieldFrame, southWest: SIMD2<Double>, spacing: Double, columns: Int, rows: Int,
                heights: [Double], source: String) {
        precondition(heights.count == columns * rows, "heights must fill the grid")
        self.frame = frame
        self.southWest = southWest
        self.spacing = spacing
        self.columns = columns
        self.rows = rows
        self.heights = heights
        self.source = source
    }

    public func height(column c: Int, row r: Int) -> Double { heights[r * columns + c] }

    /// ENU of a sample.
    public func position(column c: Int, row r: Int) -> SIMD2<Double> {
        southWest + SIMD2(Double(c), Double(r)) * spacing
    }

    /// Bilinear height at ENU east/north; nil outside the grid.
    public func height(east: Double, north: Double) -> Double? {
        let x = (east - southWest.x) / spacing, y = (north - southWest.y) / spacing
        guard x >= 0, y >= 0, x <= Double(columns - 1), y <= Double(rows - 1) else { return nil }
        let c0 = min(Int(x), columns - 2), r0 = min(Int(y), rows - 2)
        let fx = x - Double(c0), fy = y - Double(r0)
        let h00 = height(column: c0, row: r0), h10 = height(column: c0 + 1, row: r0)
        let h01 = height(column: c0, row: r0 + 1), h11 = height(column: c0 + 1, row: r0 + 1)
        let v = h00 * (1 - fx) * (1 - fy) + h10 * fx * (1 - fy) + h01 * (1 - fx) * fy + h11 * fx * fy
        return v.isNaN ? nil : v
    }

    /// The sample points to query a height service for, covering `boundary` with a margin.
    public static func samplePoints(covering boundary: [GeoPoint], frame: FieldFrame, spacing: Double,
                                    margin: Double = 20) -> (southWest: SIMD2<Double>, columns: Int, rows: Int, points: [GeoPoint]) {
        let en = boundary.map { frame.enu($0) }
        let minX = (en.map(\.x).min() ?? 0) - margin, maxX = (en.map(\.x).max() ?? 0) + margin
        let minY = (en.map(\.y).min() ?? 0) - margin, maxY = (en.map(\.y).max() ?? 0) + margin
        let columns = max(2, Int(((maxX - minX) / spacing).rounded(.up)) + 1)
        let rows = max(2, Int(((maxY - minY) / spacing).rounded(.up)) + 1)
        var points: [GeoPoint] = []
        for r in 0..<rows {
            for c in 0..<columns {
                points.append(frame.geo(SIMD3(minX + Double(c) * spacing, minY + Double(r) * spacing, 0)).point)
            }
        }
        return (SIMD2(minX, minY), columns, rows, points)
    }
}
