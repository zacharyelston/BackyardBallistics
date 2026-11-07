import Foundation

public struct GeoPoint: Codable, Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// Small-area geo helpers. Accurate to well under a centimetre over a backyard.
public enum Geo {
    public static let earthRadius = 6_371_000.0

    /// Point `east` and `north` metres from `origin`.
    public static func offset(_ origin: GeoPoint, east: Double, north: Double) -> GeoPoint {
        let lat = origin.latitude + RangeMath.degrees(north / earthRadius)
        let lon = origin.longitude + RangeMath.degrees(east / (earthRadius * cos(RangeMath.radians(origin.latitude))))
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// Ground distance between two points, metres.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let lat = RangeMath.radians((a.latitude + b.latitude) / 2)
        let dn = RangeMath.radians(b.latitude - a.latitude) * earthRadius
        let de = RangeMath.radians(b.longitude - a.longitude) * earthRadius * cos(lat)
        return (dn * dn + de * de).squareRoot()
    }

    /// ARKit world offset (x, z) to east/north, for a session run with `.gravityAndHeading`
    /// (+X east, -Z north).
    public static func eastNorth(arOffset o: SIMD2<Double>) -> (east: Double, north: Double) {
        (o.x, -o.y)
    }
}

/// The safety gate: a ranged lid must land near a published flag, so the app ranges
/// course flags and nothing else.
public enum FlagGate {
    public static let toleranceMetres = 10.0

    public struct Result: Sendable {
        public var rangedLid: GeoPoint
        public var missMetres: Double
        public var passed: Bool
    }

    /// - Parameters:
    ///   - lie: GPS position where the first photo was taken.
    ///   - report: the ranging result (its offset is in a `.gravityAndHeading` ARKit world).
    ///   - flag: the published flag point.
    public static func check(lie: GeoPoint, report: RangeReport, flag: GeoPoint,
                             tolerance: Double = toleranceMetres) -> Result {
        let en = Geo.eastNorth(arOffset: report.offset)
        let lid = Geo.offset(lie, east: en.east, north: en.north)
        let miss = Geo.distance(lid, flag)
        return Result(rangedLid: lid, missMetres: miss, passed: miss <= tolerance)
    }
}
