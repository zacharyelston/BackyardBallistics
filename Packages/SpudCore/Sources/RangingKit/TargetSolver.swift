import Foundation
import simd
import CoreGeo

// Target capture: a few ARKit-posed stills of one target, from different spots, with a scale
// stick of known length standing in every frame. Each still gives a ray from the camera through
// the target, and rays through two or more of the stick's marks. The target is where its rays
// meet; the stick, triangulated the same way, measures ARKit's scale error, which is taken out.
// The shots' GPS then places the target on the map.
//
// World frame: ARKit's `.gravityAndHeading` (+X east, +Y up, −Z north), metres.

/// A stick with coloured marks at known heights, for scale. Marks are metres from the bottom.
public struct ScaleStick: Codable, Equatable, Sendable {
    public var name: String
    public var marks: [Double]

    public init(name: String, marks: [Double]) {
        self.name = name
        self.marks = marks.sorted()
    }

    public var length: Double { (marks.last ?? 0) - (marks.first ?? 0) }

    /// 1 m with a band every 25 cm (five marks, 0 to 1 m).
    public static let meterQuarters = ScaleStick(name: "1 m, bands every 25 cm", marks: [0, 0.25, 0.5, 0.75, 1])
    /// 2 m with a band every 50 cm.
    public static let twoMeterHalves = ScaleStick(name: "2 m, bands every 50 cm", marks: [0, 0.5, 1, 1.5, 2])
}

/// One still: where the phone was (ARKit pose and lens), and what was marked on it.
public struct TargetSighting: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var date: Date
    public var pose: CameraPose
    /// Intrinsics of the image the pixels were marked on (native landscape buffer pixels).
    public var intrinsics: Intrinsics
    public var target: Pixel
    /// Stick marks found on this still: index into `ScaleStick.marks`, and where it is.
    public var stickMarks: [Int: Pixel]
    public var location: GeoPoint?
    public var horizontalAccuracy: Double?
    /// The still's file name in the capture bundle, if saved.
    public var imageFile: String?

    public init(id: UUID = UUID(), date: Date = Date(), pose: CameraPose, intrinsics: Intrinsics, target: Pixel,
                stickMarks: [Int: Pixel] = [:], location: GeoPoint? = nil, horizontalAccuracy: Double? = nil,
                imageFile: String? = nil) {
        self.id = id
        self.date = date
        self.pose = pose
        self.intrinsics = intrinsics
        self.target = target
        self.stickMarks = stickMarks
        self.location = location
        self.horizontalAccuracy = horizontalAccuracy
        self.imageFile = imageFile
    }

    public var targetRay: Ray3 { pose.ray(through: target, intrinsics: intrinsics) }
}

/// Where the target is, and how sure we can be.
public struct TargetFix: Equatable, Sendable {
    /// In ARKit's world frame, after the stick's scale correction.
    public var position: SIMD3<Double>
    /// Root-mean-square distance from the corrected target to its rays, metres.
    public var missRMS: Double
    /// Widest angle between two target rays, degrees. Under about 5° the depth is poorly fixed.
    public var spreadDegrees: Double
    /// True length ÷ measured length of the stick, applied about the cameras' centroid. 1 = none.
    public var scale: Double
    /// The stick as triangulated before correction, metres; nil if no two marks were seen twice.
    public var measuredStick: Double?
    /// The known length between the same marks.
    public var knownStick: Double?
    public var shots: Int
    /// The target on the map, from each shot's GPS (weighted by accuracy), if the shots had GPS.
    public var location: GeoPoint?
    /// The target's height above (+) or below the shots' mean camera height, metres.
    public var heightFromCameras: Double

    /// The scale correction as a percentage, + when ARKit read short.
    public var scaleCorrectionPercent: Double { (scale - 1) * 100 }
    public var wellConditioned: Bool { spreadDegrees >= TargetSolver.minSpreadDegrees }
}

public enum TargetSolver {
    /// Rays meeting at less than this give a poor depth.
    public static let minSpreadDegrees = 5.0
    /// A stick correction beyond this means a mismarked stick, not ARKit drift: it isn't applied.
    public static let maxScaleCorrection = 0.15

    /// The point closest to all the rays (least squares), and the RMS distance from it to them.
    /// Nil with fewer than two rays or with parallel rays.
    public static func triangulate(_ rays: [Ray3]) -> (point: SIMD3<Double>, rms: Double)? {
        guard rays.count >= 2 else { return nil }
        var A = simd_double3x3(0)
        var b = SIMD3<Double>.zero
        let I = matrix_identity_double3x3
        for r in rays {
            let d = r.direction
            let P = I - simd_double3x3(columns: (d * d.x, d * d.y, d * d.z))   // I − d dᵀ
            A += P
            b += P * r.origin
        }
        guard abs(A.determinant) > 1e-9 else { return nil }
        let p = A.inverse * b
        let rms = (rays.map { pow($0.distance(to: p), 2) }.reduce(0, +) / Double(rays.count)).squareRoot()
        return (p, rms)
    }

    /// Widest angle between any two rays' directions, degrees.
    public static func spread(_ rays: [Ray3]) -> Double {
        var best = 0.0
        for i in rays.indices {
            for j in rays.indices where j > i {
                best = max(best, acos(max(-1, min(1, simd_dot(rays[i].direction, rays[j].direction)))) * 180 / .pi)
            }
        }
        return best
    }

    public static func solve(_ sightings: [TargetSighting], stick: ScaleStick) -> TargetFix? {
        let rays = sightings.map(\.targetRay)
        guard let raw = triangulate(rays) else { return nil }

        // The stick: triangulate each mark seen on two or more shots.
        var marks: [Int: SIMD3<Double>] = [:]
        for i in stick.marks.indices {
            let r = sightings.compactMap { s in s.stickMarks[i].map { s.pose.ray(through: $0, intrinsics: s.intrinsics) } }
            if let m = triangulate(r) { marks[i] = m.point }
        }
        var measured: Double?, known: Double?
        var scale = 1.0
        let found = marks.keys.sorted()
        if found.count >= 2 {
            // Least-squares scale over consecutive found marks: Σ known·measured / Σ measured².
            var num = 0.0, den = 0.0, m = 0.0, k = 0.0
            for (a, b) in zip(found, found.dropFirst()) {
                let dm = simd_length(marks[b]! - marks[a]!)
                let dk = stick.marks[b] - stick.marks[a]
                num += dk * dm; den += dm * dm; m += dm; k += dk
            }
            measured = m
            known = k
            if den > 0 {
                let s = num / den
                if abs(s - 1) <= maxScaleCorrection { scale = s }
            }
        }

        // ARKit's scale error grows with distance travelled; correct it about the cameras' centroid.
        let centres = sightings.map(\.pose.position)
        let centroid = centres.reduce(.zero, +) / Double(centres.count)
        let position = centroid + scale * (raw.point - centroid)

        return TargetFix(position: position, missRMS: raw.rms * scale, spreadDegrees: spread(rays), scale: scale,
                         measuredStick: measured, knownStick: known, shots: sightings.count,
                         location: geolocate(position, sightings: sightings, centroid: centroid, scale: scale),
                         heightFromCameras: position.y - centroid.y)
    }

    /// The target's GPS: each shot's GPS plus the (scale-corrected) offset from that shot to the
    /// target, averaged with weights 1/accuracy². ARKit's world is gravity- and heading-aligned.
    static func geolocate(_ target: SIMD3<Double>, sightings: [TargetSighting], centroid: SIMD3<Double>,
                          scale: Double) -> GeoPoint? {
        var lat = 0.0, lon = 0.0, wsum = 0.0
        for s in sightings {
            guard let gps = s.location else { continue }
            let cam = centroid + scale * (s.pose.position - centroid)
            let d = target - cam
            let p = Geo.offset(gps, east: d.x, north: -d.z)
            let w = 1 / pow(max(1, s.horizontalAccuracy ?? 5), 2)
            lat += w * p.latitude; lon += w * p.longitude; wsum += w
        }
        guard wsum > 0 else { return nil }
        return GeoPoint(latitude: lat / wsum, longitude: lon / wsum)
    }
}
