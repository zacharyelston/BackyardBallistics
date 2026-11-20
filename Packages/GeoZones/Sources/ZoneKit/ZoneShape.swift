import CoreGeo
import Foundation

/// Local-area shapes. Distances and accuracy margins are in metres.
public enum ZoneShape: Codable, Equatable, Sendable {
    case circle(center: GeoPoint, radius: Double)
    case polygon(vertices: [GeoPoint])

    public var labelPoint: GeoPoint {
        switch self {
        case let .circle(center, _): return center
        case let .polygon(vertices):
            guard !vertices.isEmpty else { return GeoPoint(latitude: 0, longitude: 0) }
            let average = GeoPoint(latitude: vertices.map(\.latitude).reduce(0, +) / Double(vertices.count),
                                   longitude: vertices.map(\.longitude).reduce(0, +) / Double(vertices.count))
            return GeoPolygon(vertices).contains(average) ? average : vertices[0]
        }
    }

    public var validationError: String? {
        func valid(_ p: GeoPoint) -> Bool {
            p.latitude.isFinite && p.longitude.isFinite && abs(p.latitude) <= 85 && abs(p.longitude) <= 180
        }
        switch self {
        case let .circle(center, radius):
            guard valid(center), radius.isFinite, (10...10_000).contains(radius) else {
                return "Choose a valid centre and a radius from 10 to 10,000 metres."
            }
        case let .polygon(vertices):
            guard (3...64).contains(vertices.count), vertices.allSatisfy(valid) else {
                return "A polygon needs 3 to 64 valid map points."
            }
            guard let first = vertices.first, vertices.allSatisfy({ Geo.distance(first, $0) <= 50_000 }),
                  (vertices.map(\.longitude).max()! - vertices.map(\.longitude).min()!) < 180 else {
                return "Keep a zone within 50 km and on one side of the date line."
            }
            let points = vertices.map { Geo.eastNorth(of: $0, from: first) }
            func cross(_ a: (east: Double, north: Double), _ b: (east: Double, north: Double),
                       _ c: (east: Double, north: Double)) -> Double {
                (b.east - a.east) * (c.north - a.north) - (b.north - a.north) * (c.east - a.east)
            }
            var area = 0.0
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                guard hypot(a.east - b.east, a.north - b.north) >= 1 else { return "Keep polygon points at least a metre apart." }
                area += a.east * b.north - b.east * a.north
                for j in points.indices where j > i + 1 && !(i == 0 && j == points.count - 1) {
                    let c = points[j], d = points[(j + 1) % points.count]
                    let abC = cross(a, b, c), abD = cross(a, b, d), cdA = cross(c, d, a), cdB = cross(c, d, b)
                    let boxesOverlap = max(min(a.east, b.east), min(c.east, d.east)) <= min(max(a.east, b.east), max(c.east, d.east))
                        && max(min(a.north, b.north), min(c.north, d.north)) <= min(max(a.north, b.north), max(c.north, d.north))
                    if boxesOverlap && abC * abD <= 0 && cdA * cdB <= 0 { return "Polygon edges cannot cross or touch each other." }
                }
            }
            guard abs(area) >= 2 else { return "Draw a polygon with an area of at least one square metre." }
        }
        return nil
    }

    /// Positive inside, negative outside; zero at the boundary.
    public func clearance(at point: GeoPoint) -> Double {
        switch self {
        case let .circle(center, radius): return radius - Geo.distance(center, point)
        case let .polygon(vertices):
            guard vertices.count >= 3 else { return -.infinity }
            let points = vertices.map { Geo.eastNorth(of: $0, from: point) }
            let distance = points.indices.map { i -> Double in
                let a = points[i], b = points[(i + 1) % points.count]
                let dx = b.east - a.east, dy = b.north - a.north
                let length = dx * dx + dy * dy
                let t = length > 0 ? min(1, max(0, -(a.east * dx + a.north * dy) / length)) : 0
                return hypot(a.east + t * dx, a.north + t * dy)
            }.min() ?? 0
            return GeoPolygon(vertices).contains(point) ? distance : -distance
        }
    }
}
