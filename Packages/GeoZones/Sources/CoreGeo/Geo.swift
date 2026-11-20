import Foundation

public struct GeoPoint: Codable, Equatable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
}

/// Small-area geo helpers. Accurate to well under a centimetre over a backyard.
public enum Geo {
    public static let earthRadius = 6_371_000.0

    @inlinable public static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }
    @inlinable public static func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    /// Point `east` and `north` metres from `origin`.
    public static func offset(_ origin: GeoPoint, east: Double, north: Double) -> GeoPoint {
        let lat = origin.latitude + degrees(north / earthRadius)
        let lon = origin.longitude + degrees(east / (earthRadius * cos(radians(origin.latitude))))
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// Metres east and north of `origin` to reach `p`.
    public static func eastNorth(of p: GeoPoint, from origin: GeoPoint) -> (east: Double, north: Double) {
        let lat = radians((origin.latitude + p.latitude) / 2)
        return (radians(p.longitude - origin.longitude) * earthRadius * cos(lat),
                radians(p.latitude - origin.latitude) * earthRadius)
    }

    /// Ground distance between two points, metres.
    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let en = eastNorth(of: b, from: a)
        return (en.east * en.east + en.north * en.north).squareRoot()
    }

    /// Compass bearing from `a` to `b`, degrees clockwise from north.
    public static func bearing(from a: GeoPoint, to b: GeoPoint) -> Double {
        let en = eastNorth(of: b, from: a)
        let d = degrees(atan2(en.east, en.north))
        return d < 0 ? d + 360 : d
    }

    /// Point `distance` metres from `origin` along compass `bearing` degrees.
    public static func destination(_ origin: GeoPoint, bearing: Double, distance: Double) -> GeoPoint {
        offset(origin, east: distance * sin(radians(bearing)), north: distance * cos(radians(bearing)))
    }

    /// ARKit world offset (x, z) to east/north, for a session run with `.gravityAndHeading`
    /// (+X east, -Z north).
    public static func eastNorth(arOffset x: Double, _ z: Double) -> (east: Double, north: Double) {
        (x, -z)
    }
}

/// A closed boundary such as a course's property line.
public struct GeoPolygon: Codable, Equatable, Sendable {
    public var vertices: [GeoPoint]
    public init(_ vertices: [GeoPoint]) { self.vertices = vertices }

    /// Even-odd point-in-polygon on a local flat projection.
    public func contains(_ p: GeoPoint) -> Bool {
        guard vertices.count >= 3 else { return false }
        let pts = vertices.map { Geo.eastNorth(of: $0, from: p) }
        var inside = false
        var j = pts.count - 1
        for i in pts.indices {
            let (xi, yi) = (pts[i].east, pts[i].north)
            let (xj, yj) = (pts[j].east, pts[j].north)
            if (yi > 0) != (yj > 0) && 0 < (xj - xi) * (0 - yi) / (yj - yi) + xi { inside.toggle() }
            j = i
        }
        return inside
    }
}
