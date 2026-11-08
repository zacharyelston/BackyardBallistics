import Foundation
import RangingKit
import RoundKit

/// A check fire call. Its ID lets the match host and commanders agree on when it was seen and withdrawn.
public struct CheckFire: Codable, Hashable, Sendable {
    public var id: UUID
    public var by: DeviceID
    public init(id: UUID = UUID(), by: DeviceID) { self.id = id; self.by = by }
}

/// The round a commander wants spotted.
public struct SpotRequest: Codable, Equatable, Sendable {
    public var hole: Int
    public var mission: Int
    public var round: Int
}

/// The commander's answer to a member's report.
public struct Ack: Codable, Equatable, Sendable {
    public var id: UUID
    public var applied: Bool
    public var reason: String?
}

/// One round as members see it: the spot and fire control's change in metres. Never a firing solution.
public struct RoundLine: Codable, Equatable, Sendable {
    public var number: Int
    public var mission: Int
    public var call: RangeCall?
    public var lateral: Double?
    public var addDrop: Double?
    public var rightLeft: Double?
    public var lost: Bool
}

/// What a commander sends its members after every change.
public struct SquadView: Codable, Equatable, Sendable {
    public var revision: Int
    public var squad: String
    public var hole: Int?
    public var phase: HolePlay.Phase?
    public var rounds: [RoundLine]
    public var scores: [Int: Double]
    public var yourTurn: Bool
    public var holds: [Hold]
}

/// What a commander tells the match host about its squad.
public struct SquadStatus: Codable, Equatable, Sendable {
    public var squad: SquadID
    public var revision: Int
    public var hole: Int?
    public var phase: HolePlay.Phase?
    /// Firing point index (`M` − 1) for the current hole, for the fan check.
    public var firingPoint: Int
    /// Set once the hole is finished.
    public var score: Double?
}

/// A squad as the match host knows it.
public struct SquadEntry: Codable, Equatable, Sendable {
    public var squad: SquadID
    public var name: String
    public var members: [MemberID]
}

/// The match, as the match host sends it to every commander.
public struct MatchView: Codable, Equatable, Sendable {
    public var revision: Int
    public var hole: Int?
    public var order: [SquadID]
    /// The squad whose turn it is; nil before the start, between holes or at the end.
    public var current: SquadID?
    public var scores: [SquadID: [Int: Double]]
    /// Field-wide holds (walking out, check fire, the fan). `notYourTurn` is worked out by each commander.
    public var holds: [Hold]
    public var activeCheckFires: [CheckFire]
    /// Every check fire the match host has processed, withdrawn or not.
    public var seenCheckFires: Set<UUID>
    public var finished: Bool
}

/// A member's request to join a squad.
public struct JoinRequest: Codable, Equatable, Sendable {
    public var member: MemberID
    public var name: String
    public var courseID: String
    public var courseVersion: Int
}

/// Everything that goes over the wire in v3 Squadz.
public enum GroupMessage: Codable, Equatable, Sendable {
    // Member's phone → commander. These are the only messages a member may send.
    case join(JoinRequest)
    case position(MemberPosition)
    case lock(LockReport)
    case spot(SpotReport)
    case fired(hole: Int, mission: Int)
    case checkFire(CheckFire)
    case bye

    // Commander → members.
    case joined(Member)
    case refused(reason: String)
    case squadView(SquadView)
    case spotRequest(SpotRequest)
    case ack(Ack)

    // Commander → match host.
    case register(SquadEntry)
    case squadStatus(SquadStatus)
    case memberPositions(squad: SquadID, [MemberPosition])
    case checkFireRaised(CheckFire)

    // Match host → commanders.
    case matchView(MatchView)

    /// Whether a member's phone may send this. A commander drops anything else from a member.
    public var isMemberMessage: Bool {
        switch self {
        case .join, .position, .lock, .spot, .fired, .checkFire, .bye: return true
        default: return false
        }
    }
}

/// A message with its sender, as it travels.
public struct Envelope: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var sender: DeviceID
    public var seq: Int
    public var body: GroupMessage
    public init(protocolVersion: Int = GroupRules.protocolVersion, sender: DeviceID, seq: Int, body: GroupMessage) {
        self.protocolVersion = protocolVersion
        self.sender = sender
        self.seq = seq
        self.body = body
    }
}

/// A message a host wants sent.
public struct Outbound: Equatable, Sendable {
    public var to: DeviceID
    public var message: GroupMessage
    public init(to: DeviceID, _ message: GroupMessage) { self.to = to; self.message = message }
}
