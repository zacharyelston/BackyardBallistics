import Foundation
import CoreGeo
import RangingKit

/// v3 Squadz game rules that are about play, not safety. Safety numbers stay in SafetyKit.
public enum GroupRules {
    /// The wire format. A device with a different version can't join.
    public static let protocolVersion = 1
    /// A member's position older than this is stale: shown faded, and unknown for the fan hold.
    public static let positionStaleSeconds = 30.0
    /// A commander that hasn't heard from the match host for this long holds its squad.
    public static let matchLeaseSeconds = 10.0
    /// A member this close to the active firing point (plus their GPS accuracy) is at the line, not downrange.
    public static let lineStandoff = 3.0
}

public struct DeviceID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { String(raw.uuidString.prefix(8)) }
}

public struct MemberID: Codable, Hashable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

public struct SquadID: Codable, Hashable, Sendable {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
}

public struct Member: Codable, Equatable, Sendable, Identifiable {
    public var id: MemberID
    public var name: String
    public var device: DeviceID
    public init(id: MemberID = MemberID(), name: String, device: DeviceID) {
        self.id = id
        self.name = name
        self.device = device
    }
}

/// A squad: the player in v3 Squadz. Its name is the player on the scorecard.
public struct Squad: Codable, Equatable, Sendable, Identifiable {
    public var id: SquadID
    public var name: String
    /// The commander's iPad, which hosts the squad.
    public var commander: DeviceID
    public var members: [Member]
    public init(id: SquadID = SquadID(), name: String, commander: DeviceID, members: [Member] = []) {
        self.id = id
        self.name = name
        self.commander = commander
        self.members = members
    }
    public func member(on device: DeviceID) -> Member? { members.first { $0.device == device } }
}

/// Where a member's phone says it is.
public struct MemberPosition: Codable, Equatable, Sendable {
    public var member: MemberID
    public var at: GeoPoint
    /// GPS horizontal accuracy, metres.
    public var accuracy: Double
    public var heading: Double?
    public var time: Date
    public init(member: MemberID, at: GeoPoint, accuracy: Double, heading: Double? = nil, time: Date) {
        self.member = member
        self.at = at
        self.accuracy = accuracy
        self.heading = heading
        self.time = time
    }
    public func isStale(now: Date) -> Bool { now.timeIntervalSince(time) > GroupRules.positionStaleSeconds }
}

/// A raw reticle lock from a member's phone. The commander recomputes and gates it; it is never trusted as cleared.
public struct LockReport: Codable, Equatable, Sendable {
    public enum Purpose: String, Codable, Sendable {
        /// The squad's first mission on the hole, from the firing point.
        case initial
        /// A downrange mission, from the closest round.
        case nextMission
        /// After cease fire: the range from the closest round to the pole.
        case verify
        /// For the field map only.
        case observation
    }
    public var id: UUID
    public var hole: Int
    public var purpose: Purpose
    public var lock: ReticleLock
    public init(id: UUID = UUID(), hole: Int, purpose: Purpose, lock: ReticleLock) {
        self.id = id
        self.hole = hole
        self.purpose = purpose
        self.lock = lock
    }
}

/// A member's spot for the round in flight: a proposal. Only the commander commits a spot.
public struct SpotReport: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var hole: Int
    public var mission: Int
    /// The round's number on the hole (`FiredRound.number`).
    public var round: Int
    public var call: RangeCall
    /// Measured left/right, metres (+ right of the pole); nil if not measured.
    public var lateral: Double?
    /// Where the spotter stood, for flank geometry.
    public var vantage: GeoPoint?
    public init(id: UUID = UUID(), hole: Int, mission: Int, round: Int, call: RangeCall, lateral: Double?, vantage: GeoPoint? = nil) {
        self.id = id
        self.hole = hole
        self.mission = mission
        self.round = round
        self.call = call
        self.lateral = lateral
        self.vantage = vantage
    }
}
