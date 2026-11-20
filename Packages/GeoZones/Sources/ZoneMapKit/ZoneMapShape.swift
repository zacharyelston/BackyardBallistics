import CoreGeo
import MapKit
import SwiftUI
import ZoneKit

/// A reusable map layer for circles and polygon boundaries. Each app chooses its own styling.
public struct ZoneMapShape: MapContent {
    public var shape: ZoneShape
    public var fill: Color
    public var stroke: Color
    public var lineWidth: CGFloat
    public init(_ shape: ZoneShape, fill: Color, stroke: Color, lineWidth: CGFloat = 1) {
        self.shape = shape; self.fill = fill; self.stroke = stroke; self.lineWidth = lineWidth
    }
    public var body: some MapContent {
        switch shape {
        case let .circle(center, radius):
            MapCircle(center: center.coordinate, radius: radius)
                .foregroundStyle(fill).stroke(stroke, lineWidth: lineWidth)
        case let .polygon(vertices):
            MapPolygon(coordinates: vertices.map(\.coordinate))
                .foregroundStyle(fill).stroke(stroke, lineWidth: lineWidth)
        }
    }
}

public extension ZoneShape {
    /// UIKit/AppKit maps use the same geometry as the SwiftUI layer. Two corners preview a draft.
    func mapOverlay() -> (any MKOverlay)? {
        switch self {
        case let .circle(center, radius):
            guard radius.isFinite, radius > 0, radius <= 10_000 else { return nil }
            return MKCircle(center: center.coordinate, radius: radius)
        case let .polygon(vertices):
            let points = vertices.map(\.coordinate)
            if points.count >= 3 { return MKPolygon(coordinates: points, count: points.count) }
            if points.count >= 2 { return MKPolyline(coordinates: points, count: points.count) }
            return nil
        }
    }
}

private extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
