import Foundation
import CoreGeo
import CourseKit
import FieldKit

/// One photo's camera: where the reconstruction put it, and where its GPS says it was.
public struct CameraPair: Equatable, Sendable {
    /// Camera centre in the reconstruction's frame (the USDZ's coordinates, y up).
    public var reconstructed: SIMD3<Double>
    public var geotag: PhotoGeotag

    public init(reconstructed: SIMD3<Double>, geotag: PhotoGeotag) {
        self.reconstructed = reconstructed
        self.geotag = geotag
    }
}

public enum CameraPairing {
    /// Matches reconstructed camera positions (keyed by their photo's URL) with geotags. Photos are
    /// matched by their resolved path, then by file name if that is unique on both sides. Cameras
    /// with no geotag, and geotags with no camera, are left out. Sorted by file name.
    public static func pair(cameras: [URL: SIMD3<Double>], geotags: [PhotoGeotag]) -> [CameraPair] {
        func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
        var byPath: [String: PhotoGeotag] = [:]
        var byName: [String: [PhotoGeotag]] = [:]
        for tag in geotags {
            byPath[key(tag.url)] = tag
            byName[tag.url.lastPathComponent, default: []].append(tag)
        }
        let cameraNames = Dictionary(grouping: cameras.keys, by: \.lastPathComponent)

        var pairs: [CameraPair] = []
        for (url, position) in cameras {
            if let tag = byPath[key(url)] {
                pairs.append(CameraPair(reconstructed: position, geotag: tag))
            } else if let tags = byName[url.lastPathComponent], tags.count == 1,
                      cameraNames[url.lastPathComponent]?.count == 1 {
                pairs.append(CameraPair(reconstructed: position, geotag: tags[0]))
            }
        }
        return pairs.sorted {
            $0.geotag.url.lastPathComponent.localizedStandardCompare($1.geotag.url.lastPathComponent) == .orderedAscending
        }
    }
}

/// Pins a reconstruction to the course's ENU frame from its cameras' GPS.
///
/// **Weights.** Each camera counts 1/σ², σ its EXIF horizontal accuracy (clamped to at least
/// `minAccuracy`; `defaultAccuracy` when the photo doesn't say).
///
/// **Altitude.** Phone GPS altitude is usually two or three times worse than its horizontal
/// position, and EXIF carries no vertical accuracy. So by default the fit is *horizontal*: every
/// camera's target height is the same, `handHeight` above the frame's zero, which says "the photos
/// were taken walking the yard at chest height". Then the cameras' plane becomes level, and
/// east/north do the rest. That is right for a roughly level yard and tilts the mesh by about the
/// yard's mean slope otherwise. Only when *every* paired photo has an altitude and a horizontal
/// accuracy within `altitudeAccuracyLimit` does the fit use the GPS altitudes in 3D.
///
/// **Frame height.** The frame's `originAltitude` is the median GPS altitude minus `handHeight`
/// (roughly the ground), or 0 if no photo has an altitude.
///
/// **Outliers.** After one fit, cameras farther from their GPS than `max(outlierFactor × RMS,
/// minOutlierResidual)` are dropped and the fit is run again, once, if at least 3 cameras remain.
///
/// **Residual.** `residualRMS` is measured against what the GPS was trusted for: east/north in a
/// horizontal fit, all three axes in a 3D fit.
public struct Georeference: Sendable {
    public enum Mode: String, Sendable { case horizontal, threeD = "3d" }

    public struct Settings: Sendable {
        public var handHeight = 1.5
        public var defaultAccuracy = 5.0
        public var minAccuracy = 1.0
        public var altitudeAccuracyLimit = 3.0
        public var outlierFactor = 3.0
        public var minOutlierResidual = 3.0
        /// The cameras' horizontal spread must be at least this wide across its narrow axis, metres.
        public var minSpread = 1.0
        public init() {}
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case tooFewCameras(Int)
        case camerasInALine
        case fitFailed

        public var description: String {
            switch self {
            case .tooFewCameras(let n):
                return "Only \(n) photo\(n == 1 ? "" : "s") have both GPS and a reconstructed camera; at least 3 are needed to place the mesh."
            case .camerasInALine:
                return "The geotagged photos lie along one line, so the mesh can't be oriented. Walk the yard's boundary, not one path."
            case .fitFailed:
                return "The cameras couldn't be fitted to their GPS positions (are the photos' locations right?)."
            }
        }
    }

    public var mode: Mode
    public var frame: FieldFrame
    public var toENU: Similarity3
    public var residualRMS: Double
    /// East/north RMS, metres, whatever the mode.
    public var horizontalRMS: Double
    /// The cameras the final fit used, and those dropped as outliers.
    public var used: [CameraPair]
    public var rejected: [CameraPair]

    /// Fits the pairs; `origin` is the frame's origin (the course's flag 1, or its first boundary vertex).
    public static func fit(_ pairs: [CameraPair], origin: GeoPoint, settings: Settings = Settings()) throws -> Georeference {
        guard pairs.count >= 3 else { throw Failure.tooFewCameras(pairs.count) }
        let mode = Self.mode(for: pairs.map(\.geotag), settings: settings)
        let frame = Self.frame(origin: origin, geotags: pairs.map(\.geotag), settings: settings)
        let targets = pairs.map { target(for: $0.geotag, frame: frame, mode: mode, settings: settings) }
        guard horizontalSpread(targets) >= settings.minSpread else { throw Failure.camerasInALine }

        func solve(_ idx: [Int]) -> Similarity3? {
            Similarity3.fit(from: idx.map { pairs[$0].reconstructed }, to: idx.map { targets[$0] },
                            weights: idx.map { weight(pairs[$0].geotag, settings) })
        }
        func residual(_ t: Similarity3, _ i: Int) -> SIMD3<Double> {
            var d = t.apply(pairs[i].reconstructed) - targets[i]
            if mode == .horizontal { d.z = 0 }
            return d
        }
        func rms(_ t: Similarity3, _ idx: [Int], horizontalOnly: Bool) -> Double {
            let s = idx.map { i -> Double in
                var d = residual(t, i)
                if horizontalOnly { d.z = 0 }
                return (d * d).sum()
            }.reduce(0, +)
            return (s / Double(idx.count)).squareRoot()
        }

        var idx = Array(pairs.indices)
        guard var t = solve(idx), t.scale.isFinite else { throw Failure.fitFailed }
        let first = rms(t, idx, horizontalOnly: false)
        let limit = max(settings.outlierFactor * first, settings.minOutlierResidual)
        let kept = idx.filter { let d = residual(t, $0); return (d * d).sum().squareRoot() <= limit }
        if kept.count < idx.count, kept.count >= 3,
           horizontalSpread(kept.map { targets[$0] }) >= settings.minSpread, let refit = solve(kept) {
            t = refit
            idx = kept
        }
        let keptSet = Set(idx)
        return Georeference(mode: mode, frame: frame, toENU: t,
                            residualRMS: rms(t, idx, horizontalOnly: false),
                            horizontalRMS: rms(t, idx, horizontalOnly: true),
                            used: idx.map { pairs[$0] },
                            rejected: pairs.indices.filter { !keptSet.contains($0) }.map { pairs[$0] })
    }

    /// 3D only when every photo has an altitude and good horizontal accuracy.
    public static func mode(for geotags: [PhotoGeotag], settings: Settings = Settings()) -> Mode {
        let good = geotags.allSatisfy { g in
            g.altitude != nil && (g.horizontalAccuracy.map { $0 <= settings.altitudeAccuracyLimit } ?? false)
        }
        return !geotags.isEmpty && good ? .threeD : .horizontal
    }

    public static func frame(origin: GeoPoint, geotags: [PhotoGeotag], settings: Settings = Settings()) -> FieldFrame {
        let alts = geotags.compactMap(\.altitude).sorted()
        guard !alts.isEmpty else { return FieldFrame(origin: origin, originAltitude: 0) }
        let mid = alts.count / 2
        let median = alts.count % 2 == 1 ? alts[mid] : (alts[mid - 1] + alts[mid]) / 2
        return FieldFrame(origin: origin, originAltitude: median - settings.handHeight)
    }

    public static func target(for g: PhotoGeotag, frame: FieldFrame, mode: Mode, settings: Settings = Settings()) -> SIMD3<Double> {
        var v = frame.enu(g.point, altitude: g.altitude)
        if mode == .horizontal || g.altitude == nil { v.z = settings.handHeight }
        return v
    }

    public static func weight(_ g: PhotoGeotag, _ settings: Settings = Settings()) -> Double {
        let sigma = max(g.horizontalAccuracy ?? settings.defaultAccuracy, settings.minAccuracy)
        return 1 / (sigma * sigma)
    }

    /// The standard deviation of the points' east/north positions across their narrowest axis.
    static func horizontalSpread(_ points: [SIMD3<Double>]) -> Double {
        guard points.count >= 2 else { return 0 }
        let n = Double(points.count)
        let mx = points.map(\.x).reduce(0, +) / n, my = points.map(\.y).reduce(0, +) / n
        var sxx = 0.0, syy = 0.0, sxy = 0.0
        for p in points {
            sxx += (p.x - mx) * (p.x - mx); syy += (p.y - my) * (p.y - my); sxy += (p.x - mx) * (p.y - my)
        }
        sxx /= n; syy /= n; sxy /= n
        let tr = sxx + syy, det = sxx * syy - sxy * sxy
        let smallest = tr / 2 - max(0, tr * tr / 4 - det).squareRoot()
        return max(0, smallest).squareRoot()
    }
}

/// The frame origin for a course: hole 1's flag, or else the boundary's first vertex.
public enum MeshOrigin {
    public static func origin(for course: Course) -> (point: GeoPoint, label: String)? {
        if let hole = course.holes.first(where: { $0.number == 1 }) ?? course.holes.min(by: { $0.number < $1.number }) {
            return (hole.flag.position, "hole \(hole.number) flag")
        }
        if let v = course.boundary.vertices.first { return (v, "boundary vertex 1") }
        return nil
    }
}
