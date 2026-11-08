import SwiftUI
import MapKit
import CoreGeo
import SafetyKit
import CourseKit
import GroupKit

// Shared by the iPhone/iPad app (the commander's squad screen) and SpudTheater (macOS).

/// What the site map needs to draw one squad: its course, its members and where they are.
struct SiteMapSquad: Identifiable {
    var id: String
    var course: Course?
    var members: [Member]
    var positions: [MemberID: MemberPosition]
    /// The hole in play, highlighted (its fan drawn strong). Nil between holes.
    var activeHole: Int?
    /// Cease fire: people are walking out, so no fan is live.
    var walkingOut: Bool
    /// Lines of sight of locks the commander used: from where the member stood to the ranged pole.
    var rays: [SiteMapRay] = []
}

struct SiteMapRay: Hashable {
    var from: GeoPoint
    var to: GeoPoint
}

/// The site: satellite imagery with each squad's course and members on it. The course boundary,
/// each hole's flag and ring, the firing points with a line to the flag, and every safety fan
/// (± SafetyKit's half-angle out to its fan radius); the hole in play is highlighted. Members are
/// GPS dots with accuracy circles, grey once their position is stale.
struct SiteMap: View {
    let squads: [SiteMapSquad]
    @State private var camera: MapCameraPosition = .automatic
    @State private var fittedTo: String?

    /// A member's position older than this is drawn grey.
    static let staleAfter: TimeInterval = 15
    private static let squadColors: [Color] = [.orange, .cyan, .pink, .yellow, .mint, .purple]

    var body: some View {
        Map(position: $camera) {
            ForEach(courses, id: \.id) { course in
                MapPolygon(coordinates: course.boundary.vertices.map(\.coordinate))
                    .foregroundStyle(.clear)
                    .stroke(.white.opacity(0.9), lineWidth: 2)
                ForEach(course.holes) { hole in
                    let active = activeHoles.contains(HoleKey(course: course.id, hole: hole.number))
                    ForEach(Array(hole.firingPoints.enumerated()), id: \.offset) { i, fp in
                        MapPolygon(coordinates: Self.fan(from: fp, to: hole.flag.position))
                            .foregroundStyle(.red.opacity(active ? 0.22 : 0.06))
                            .stroke(.red.opacity(active ? 0.8 : 0.25), lineWidth: active ? 1.5 : 0.5)
                        MapPolyline(coordinates: [fp.coordinate, hole.flag.position.coordinate])
                            .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        Annotation("\(hole.number)·\(i + 1)", coordinate: fp.coordinate, anchor: .center) {
                            Image(systemName: "triangle.fill").font(.caption2).foregroundStyle(.white)
                        }
                    }
                    MapCircle(center: hole.flag.position.coordinate, radius: hole.flag.inRadiusM)
                        .foregroundStyle(.green.opacity(0.35))
                        .stroke(.green, lineWidth: 1)
                    Annotation("Hole \(hole.number)", coordinate: hole.flag.position.coordinate, anchor: .bottom) {
                        Image(systemName: "flag.fill").foregroundStyle(.red).shadow(radius: 2)
                    }
                }
            }
            ForEach(Array(squads.enumerated()), id: \.element.id) { i, squad in
                let color = Self.squadColors[i % Self.squadColors.count]
                ForEach(Array(squad.rays.enumerated()), id: \.offset) { _, ray in
                    MapPolyline(coordinates: [ray.from.coordinate, ray.to.coordinate])
                        .stroke(color.opacity(0.9), lineWidth: 1)
                }
                ForEach(squad.members) { m in
                    if let p = squad.positions[m.id] {
                        let stale = Date().timeIntervalSince(p.time) > Self.staleAfter
                        MapCircle(center: p.at.coordinate, radius: max(1, p.accuracy))
                            .foregroundStyle(color.opacity(0.15))
                        Annotation(m.name, coordinate: p.at.coordinate) {
                            Circle().fill(stale ? .gray : color)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                    }
                }
            }
        }
        .mapStyle(.hybrid(elevation: .realistic))
        .mapControls {
            MapCompass()
            MapScaleView()
            #if os(macOS)
            MapZoomStepper()
            #endif
            MapPitchToggle()
        }
        .overlay(alignment: .topLeading) {
            Button { fit(force: true) } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .buttonStyle(.borderedProminent)
            .tint(.black.opacity(0.55))
            .padding(10)
            .help("Fit the map to the course and its members")
        }
        .onAppear { fit(force: false) }
        .onChange(of: courses.map(\.id)) { _, _ in fit(force: false) }
    }

    private struct HoleKey: Hashable { var course: String; var hole: Int }

    private var courses: [Course] {
        var seen = Set<String>()
        return squads.compactMap(\.course).filter { seen.insert($0.id).inserted }
    }

    private var activeHoles: Set<HoleKey> {
        Set(squads.compactMap { s in
            guard let c = s.course, let h = s.activeHole, !s.walkingOut else { return nil }
            return HoleKey(course: c.id, hole: h)
        })
    }

    /// Frames the course and every member with a position. On its own only once per course;
    /// the Fit button does it on demand.
    private func fit(force: Bool) {
        guard let course = courses.first, force || fittedTo != course.id else { return }
        fittedTo = course.id
        var points = course.boundary.vertices
        for s in squads { points += s.positions.values.map(\.at) }
        let rect = points.map { MKMapPoint($0.coordinate) }
            .reduce(MKMapRect.null) { $0.union(MKMapRect(origin: $1, size: MKMapSize(width: 1, height: 1))) }
        camera = .rect(rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15))
    }

    /// The safety fan from a firing point toward its flag: ± the half-angle, out to the fan radius.
    static func fan(from fp: GeoPoint, to flag: GeoPoint) -> [CLLocationCoordinate2D] {
        let limits = Safety.limits
        let centre = Geo.bearing(from: fp, to: flag)
        let arc = stride(from: -limits.fanHalfAngle, through: limits.fanHalfAngle, by: 5).map {
            Geo.destination(fp, bearing: centre + $0, distance: limits.fanRange).coordinate
        }
        return [fp.coordinate] + arc
    }
}

extension GeoPoint {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}
