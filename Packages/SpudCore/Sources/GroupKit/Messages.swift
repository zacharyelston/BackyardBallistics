import Foundation
import CoreGeo
import RangingKit
import RoundKit

// v3 Squadz: who's who, and every message that crosses between devices.
//
// Safety shape of the protocol (docs/GROUP_PLAY.md, Safety):
// - No message carries a firing solution, a charge setting, an elevation or a `Cleared` value.
//   `Cleared` isn't Codable, so it can't be put in one.
// - Nothing a phone can send confirms downrange or lifts a hold. Phones send positions, locks,
//   spots, Fired and check fire; the commander's iPad decides what to do with them.
// - A message's sender is the connection it arrived on (`PeerID`), never a field in the message.

public enum GroupProtocol {
    /// Bumped on any change to the messages. A device on another version is refused (fail closed).
    public static let version = 1
}

public struct SquadID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { String(raw.uuidString.prefix(8)) }
}

public struct MemberID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: UUID
    public init(_ raw: UUID = UUID()) { self.raw = raw }
    public var description: String { String(raw.uuidString.prefix(8)) }
}

/// One end of a link, as the transport knows it. Hosts identify senders by this, never by a field
/// a message carries about itself.
public struct PeerID: Codable, Hashable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

public enum MemberRole: String, Codable, Sendable {
    case member
    /// Lays the launcher from the data the commander reads out, and calls Fired.
    case gunner
}

public struct Member: Codable, Equatable, Sendable, Identifiable {
    public var id: MemberID
    public var name: String
    /// The phone's own ID, so a member who drops out rejoins as the same member.
    public var device: UUID
    public var role: MemberRole

    public init(id: MemberID = MemberID(), name: String, device: UUID, role: MemberRole = .member) {
        self.id = id
        self.name = name
        self.device = device
        self.role = role
    }
}

/// The squad is the player: its name goes on the scorecard.
public struct Squad: Codable, Equatable, Sendable {
    public var id: SquadID
    public var name: String
    public var members: [Member]

    public init(id: SquadID = SquadID(), name: String, members: [Member] = []) {
        self.id = id
        self.name = name
        self.members = members
    }
}

// MARK: Payloads

public struct Hello: Codable, Equatable, Sendable {
    public var name: String
    public var device: UUID
    public var joinCode: String
    public init(name: String, device: UUID, joinCode: String) {
        self.name = name
        self.device = device
        self.joinCode = joinCode
    }
}

public struct MemberPosition: Codable, Equatable, Sendable {
    /// Set by the commander from the connection; whatever a phone puts here is overwritten.
    public var member: MemberID?
    public var at: GeoPoint
    /// GPS horizontal accuracy, metres.
    public var accuracy: Double
    public var heading: Double?
    public var time: Date

    public init(member: MemberID? = nil, at: GeoPoint, accuracy: Double, heading: Double? = nil, time: Date) {
        self.member = member
        self.at = at
        self.accuracy = accuracy
        self.heading = heading
        self.time = time
    }
}

public enum LockPurpose: String, Codable, Sendable, CaseIterable {
    /// From the firing point: begins the hole's first mission.
    case initial
    /// From the closest round, in downrange play: the next mission.
    case nextMission
    /// From the closest round after cease fire: the verified distance.
    case verify
    /// For the field map only. Never used for firing.
    case observation
}

/// A member's raw reticle lock. The commander's iPad gates it against its own course flag.
public struct LockReport: Codable, Equatable, Sendable {
    public var id: UUID
    public var purpose: LockPurpose
    public var lock: ReticleLock
    public init(id: UUID = UUID(), purpose: LockPurpose, lock: ReticleLock) {
        self.id = id
        self.purpose = purpose
        self.lock = lock
    }
}

public struct SpotReport: Codable, Equatable, Sendable {
    public var id: UUID
    public var hole: Int
    public var mission: Int
    public var round: Int
    public var call: RangeCall
    /// Measured miss across the line, metres, + right. Nil if not measured.
    public var lateral: Double?
    /// Where the spotter stood, for flank geometry (FieldKit, later).
    public var vantage: GeoPoint?

    public init(id: UUID = UUID(), hole: Int, mission: Int, round: Int, call: RangeCall,
                lateral: Double?, vantage: GeoPoint? = nil) {
        self.id = id
        self.hole = hole
        self.mission = mission
        self.round = round
        self.call = call
        self.lateral = lateral
        self.vantage = vantage
    }
}

/// The gunner's "Fired": round `round` of mission `mission` is in the air.
public struct FiredReport: Codable, Equatable, Sendable {
    public var hole: Int
    public var mission: Int
    public var round: Int
    public init(hole: Int, mission: Int, round: Int) {
        self.hole = hole
        self.mission = mission
        self.round = round
    }
}

/// Anyone can call check fire, at any time. It holds every squad.
public struct CheckFire: Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var by: String
    public init(id: UUID = UUID(), by: String) {
        self.id = id
        self.by = by
    }
}

public struct Welcome: Codable, Equatable, Sendable {
    public var member: MemberID
    public var squad: Squad
}

public struct SpotRequest: Codable, Equatable, Sendable {
    public var hole: Int
    public var mission: Int
    public var round: Int
}

/// What happened to a member's lock. Carries no range: phones don't show range results in v3.
public struct LockReceipt: Codable, Equatable, Sendable {
    public var lock: UUID
    public enum Status: String, Codable, Sendable { case received, used, refused }
    public var status: Status
    public var reasons: [String]
}

/// One round as members see it: the call and fire control's correction, in metres only.
public struct RoundSummary: Codable, Equatable, Sendable {
    public var number: Int
    public var mission: Int
    public var call: RangeCall?
    public var lateral: Double?
    public var addDrop: Double?
    public var rightLeft: Double?
    public var lost: Bool
}

/// The squad's state as its members see it. No firing data.
public struct SquadStatus: Codable, Equatable, Sendable {
    public var revision: Int
    public var squad: Squad
    public var hole: Int?
    public var phase: HolePlay.Phase?
    public var walkingOut: Bool
    public var missions: Int
    public var rounds: [RoundSummary]
    public var roundInFlight: Int?
    public var total: Double
    public var toPar: Double
    public var yourTurn: Bool
    public var holds: [Hold]
}

/// The direction rounds go: from the firing position toward the flag, ± the safety fan.
public struct Fan: Codable, Equatable, Sendable {
    public var origin: GeoPoint
    public var bearing: Double
    public init(origin: GeoPoint, bearing: Double) {
        self.origin = origin
        self.bearing = bearing
    }
}

public struct JoinMatch: Codable, Equatable, Sendable {
    public var squad: SquadID
    public var name: String
    public var joinCode: String
    public var courseID: String
    public var courseVersion: Int
    public var courseHash: String
}

/// A commander's report to the match host: enough for turns, holds and the scoreboard.
public struct SquadReport: Codable, Equatable, Sendable {
    public var squad: SquadID
    public var revision: Int
    public var members: [Member]
    public var hole: Int?
    public var phase: HolePlay.Phase?
    /// People are (or may be) downrange: cease fire was called and the hole isn't finished.
    public var walkingOut: Bool
    /// The active fan while the squad could fire.
    public var fan: Fan?
    /// Finished holes: number → score.
    public var scores: [Int: Double]
}

public struct SquadEntry: Codable, Equatable, Sendable {
    public var id: SquadID
    public var name: String
}

public struct Turn: Codable, Equatable, Sendable {
    public var hole: Int
    public var squad: SquadID
}

/// The match as the match host holds it, sent to every commander as a heartbeat.
public struct MatchState: Codable, Equatable, Sendable {
    public var revision: Int
    public var courseID: String
    public var courseVersion: Int
    public var courseHash: String
    public var squads: [SquadEntry]
    public var started: Bool
    /// Whose turn, on which hole. Nil before the start and after the last hole.
    public var turn: Turn?
    public var scores: [SquadID: [Int: Double]]
    /// Holds that apply to every squad.
    public var holds: [Hold]
    /// Every check fire the match host has seen, so a commander knows its own report arrived.
    public var knownCheckFires: [UUID]

    public var finished: Bool { started && turn == nil }

    public func total(_ squad: SquadID) -> Double {
        ((scores[squad] ?? [:]).values.reduce(0, +) * 10).rounded() / 10
    }
}

/// Why no squad, or this squad, may see firing data right now. Holds only ever add to SafetyKit's
/// verdict (see `GroupGate`).
public enum Hold: Codable, Hashable, Sendable, CustomStringConvertible {
    case noMatch
    case notYourTurn
    case walkingOut(SquadID)
    case checkFire(by: String)
    case memberInFan(MemberID, name: String)
    case positionUnknown(MemberID, name: String)
    case matchHostLost

    public var description: String {
        switch self {
        case .noMatch: return "Not in a match yet."
        case .notYourTurn: return "Another squad's turn."
        case .walkingOut: return "Cease fire: people are walking out."
        case let .checkFire(by): return "Check fire, called by \(by)."
        case let .memberInFan(_, name): return "\(name) is inside the firing fan."
        case let .positionUnknown(_, name): return "No recent position from \(name)."
        case .matchHostLost: return "Lost the match host."
        }
    }
}

// MARK: Envelope

public struct GroupMessage: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    /// Per-sender sequence number, from the transport.
    public var seq: Int
    public var body: Body

    public init(protocolVersion: Int = GroupProtocol.version, seq: Int, body: Body) {
        self.protocolVersion = protocolVersion
        self.seq = seq
        self.body = body
    }

    public enum Body: Codable, Equatable, Sendable {
        // Member's phone → commander
        case hello(Hello)
        case bye
        case position(MemberPosition)
        case lock(LockReport)
        case spot(SpotReport)
        case fired(FiredReport)
        /// Phone → commander, and commander → match host.
        case checkFire(CheckFire)

        // Commander → member's phone
        case welcome(Welcome)
        case refused(String)
        case squadStatus(SquadStatus)
        case spotRequest(SpotRequest)
        case lockReceipt(LockReceipt)

        // Commander → match host
        case joinMatch(JoinMatch)
        case squadReport(SquadReport)
        case positions(squad: SquadID, [MemberPosition])

        // Match host → commander
        case matchState(MatchState)
    }
}

/// A message to send, with the peer it goes to.
public struct Outgoing: Equatable, Sendable {
    public var to: PeerID
    public var body: GroupMessage.Body
    public init(to: PeerID, _ body: GroupMessage.Body) {
        self.to = to
        self.body = body
    }
}
