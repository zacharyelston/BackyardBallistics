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
    /// Orders with a place on the field, drawn as pins with the kind's icon.
    var orders: [Order] = []
    /// Pointers: from a member to the place an unfinished order sends them, dashed.
    var pointers: [SiteMapRay] = []
    /// Field notes with a place, drawn as pins (with their accuracy, when known).
    var notes: [FieldNote] = []
}

extension Order.Kind {
    /// SF Symbol for the kind, on the map, the commander's buttons and the phone's banner.
    var systemImage: String {
        switch self {
        case .rangeFrom: return "scope"
        case .spot: return "eye.fill"
        case .moveTo: return "figure.walk"
        case .capture: return "camera.fill"
        case .holdPosition: return "hand.raised.fill"
        case .returnToFiringPoint: return "arrow.uturn.backward"
        case .note: return "text.bubble.fill"
        }
    }

    /// Kinds that are about a place, so the commander can set one on the map.
    var takesPlace: Bool { self == .moveTo || self == .rangeFrom || self == .capture }
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
    /// Members drawn with a selection ring (the commander picking who an order is for).
    var selected: Set<MemberID> = []
    /// A place being set for an order, drawn as a hollow pin.
    var draftPlace: GeoPoint?
    /// Called with the tapped spot when set (placing an order); otherwise taps pan as usual.
    var onTapPlace: ((GeoPoint) -> Void)?
    /// Called when a member's dot is tapped.
    var onTapMember: ((MemberID) -> Void)?
    @State private var camera: MapCameraPosition = .automatic
    @State private var fittedTo: String?

    /// A member's position older than this is drawn grey.
    static let staleAfter: TimeInterval = 15
    private static let squadColors: [Color] = [.orange, .cyan, .pink, .yellow, .mint, .purple]

    var body: some View {
        MapReader { proxy in
            map
                .onTapGesture(coordinateSpace: .local) { point in
                    guard let onTapPlace, let c = proxy.convert(point, from: .local) else { return }
                    onTapPlace(GeoPoint(latitude: c.latitude, longitude: c.longitude))
                }
        }
    }

    private var map: some View {
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
                ForEach(Array(squad.pointers.enumerated()), id: \.offset) { _, ray in
                    MapPolyline(coordinates: [ray.from.coordinate, ray.to.coordinate])
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
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
                                .padding(4)
                                .overlay(Circle().stroke(.yellow, lineWidth: selected.contains(m.id) ? 3 : 0))
                                .contentShape(Circle())
                                .onTapGesture { onTapMember?(m.id) }
                        }
                    }
                }
                ForEach(squad.orders.filter { $0.at != nil }) { order in
                    Annotation(order.kind.title, coordinate: order.at!.coordinate, anchor: .bottom) {
                        Image(systemName: order.kind.systemImage)
                            .font(.caption.weight(.bold)).foregroundStyle(.white)
                            .padding(6).background(color, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 1.5))
                    }
                }
            }
            ForEach(squads.flatMap(\.notes).filter { $0.at != nil }) { note in
                if let a = note.accuracy, a > 0 {
                    MapCircle(center: note.at!.coordinate, radius: a).foregroundStyle(.yellow.opacity(0.15))
                }
                Annotation(note.author, coordinate: note.at!.coordinate, anchor: .bottom) {
                    Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(.yellow)
                        .shadow(radius: 2).help(note.text)
                }
            }
            if let draftPlace {
                Annotation("New order", coordinate: draftPlace.coordinate, anchor: .bottom) {
                    Image(systemName: "mappin.circle").font(.title).foregroundStyle(.yellow).shadow(radius: 2)
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
