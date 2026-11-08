import Foundation
import CoreGeo

/// A loaded SpudGunGolf course: the property boundary and its holes (docs/COURSE_FORMAT.md).
public struct Course: Codable, Equatable, Sendable {
    /// Version of the key layout (`course.meta.format`).
    public var format: Int
    public var id: String
    public var name: String
    /// Bumped by the designer whenever anything moves.
    public var version: Int
    public var difficulty: String?
    public var boundary: GeoPolygon
    /// In hole-number order.
    public var holes: [Hole]

    public init(format: Int, id: String, name: String, version: Int, difficulty: String? = nil,
                boundary: GeoPolygon, holes: [Hole]) {
        self.format = format
        self.id = id
        self.name = name
        self.version = version
        self.difficulty = difficulty
        self.boundary = boundary
        self.holes = holes
    }

    public var totalPar: Int { holes.reduce(0) { $0 + $1.par } }
}

public struct Hole: Codable, Equatable, Sendable, Identifiable {
    /// The `N` in `hole.N.*`.
    public var number: Int
    public var name: String
    public var par: Int
    /// Whether players may fire further missions from their closest round.
    public var downrangePlay: Bool
    /// In `M` order. Farther points make harder versions of the hole.
    public var firingPoints: [GeoPoint]
    public var flag: Flag
    public var lidDiameterM: Double?
    public var hazards: [Hazard]

    public var id: Int { number }

    public init(number: Int, name: String, par: Int, downrangePlay: Bool = false, firingPoints: [GeoPoint],
                flag: Flag, lidDiameterM: Double? = nil, hazards: [Hazard] = []) {
        self.number = number
        self.name = name
        self.par = par
        self.downrangePlay = downrangePlay
        self.firingPoints = firingPoints
        self.flag = flag
        self.lidDiameterM = lidDiameterM
        self.hazards = hazards
    }

    /// Ground distance from each firing point to the flag, metres, in firing-point order.
    public var firingDistances: [Double] { firingPoints.map { Geo.distance($0, flag.position) } }
}

public struct Flag: Codable, Equatable, Sendable {
    /// Base of the pole: the hole.
    public var position: GeoPoint
    public var poleHeightM: Double
    public var leanDeg: Double
    /// Ring radius around the pole.
    public var inRadiusM: Double

    public static let defaultInRadiusM = 1.0

    public init(position: GeoPoint, poleHeightM: Double, leanDeg: Double, inRadiusM: Double = Flag.defaultInRadiusM) {
        self.position = position
        self.poleHeightM = poleHeightM
        self.leanDeg = leanDeg
        self.inRadiusM = inRadiusM
    }
}

public struct Hazard: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case water, sand, ob
    }

    /// The `K` in `hole.N.hazard.K.*`.
    public var number: Int
    public var kind: Kind
    public var area: GeoPolygon

    public var id: Int { number }

    public init(number: Int, kind: Kind, area: GeoPolygon) {
        self.number = number
        self.kind = kind
        self.area = area
    }
}

/// Acceptance rules for a course file that are about flag kit and measurement, not safety.
/// Safety numbers (100 yd, the fan) come from SafetyKit and are never restated here.
public enum CourseRules {
    /// The only key layout this build reads.
    public static let supportedFormat = 1
    /// Pole heights the flag kit allows: 8 to 12 ft lumber, with 0.1 m of slack for a measured height.
    public static let poleHeightRangeM: ClosedRange<Double> = 2.33...3.76
    /// A flag must lean less than this (matches RangingKit's `LeanMath.limitDegrees`; a test pins it).
    public static let maxLeanDeg = 0.5
    /// Largest ring radius a course may set.
    public static let maxInRadiusM = 5.0
    /// Largest file the app will read, bytes.
    public static let maxFileBytes = 256 * 1024
}
