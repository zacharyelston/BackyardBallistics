import Foundation
import CoreGeo
import RangingKit
import RoundKit
import CourseKit

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
    public static let version = 6
}

/// Six characters, without the ones people misread (0/O, 1/I/L).
public enum JoinCode {
    public static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static func make() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet.randomElement(using: &g)! })
    }
    public static func normalized(_ code: String) -> String {
        code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
    }
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
    public enum Role: String, Codable, Sendable {
        /// A squad member's phone.
        case member
        /// A Theater station (v4): watches the squad. It receives status and positions and can
        /// send nothing that the squad acts on.
        case observer
        /// A phone connecting to a Theater host (not a squad) to send fields, notes and files.
        case contributor
    }
    public var name: String
    public var device: UUID
    public var joinCode: String
    /// Nil means member.
    public var role: Role?
    public init(name: String, device: UUID, joinCode: String, role: Role? = nil) {
        self.name = name
        self.device = device
        self.joinCode = joinCode
        self.role = role
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

/// A squad leader's order to one member, several, or the whole squad: a tasking line, like calling
/// across the yard. It carries no firing data.
public struct Order: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// Range the pole from where you are (or from `at`).
        case rangeFrom
        /// Spot the next round.
        case spot
        /// Go to `at`.
        case moveTo
        /// Take field-map captures (at `at`, if given).
        case capture
        case holdPosition
        case returnToFiringPoint
        /// Free text only.
        case note

        public var title: String {
            switch self {
            case .rangeFrom: return "Range the pole"
            case .spot: return "Spot"
            case .moveTo: return "Move to"
            case .capture: return "Capture"
            case .holdPosition: return "Hold position"
            case .returnToFiringPoint: return "Back to the firing point"
            case .note: return "Note"
            }
        }
    }

    public static let maxText = 140

    public var id: UUID
    public var kind: Kind
    public var text: String
    /// A place on the field, for move-to, range-from and capture orders.
    public var at: GeoPoint?
    /// The members it's for; nil means the whole squad.
    public var to: [MemberID]?
    public var time: Date

    public init(id: UUID = UUID(), kind: Kind, text: String, at: GeoPoint? = nil, to: [MemberID]? = nil, time: Date) {
        self.id = id
        self.kind = kind
        self.text = String(text.prefix(Self.maxText))
        self.at = at
        self.to = to
        self.time = time
    }

    public func isFor(_ member: MemberID) -> Bool { to?.contains(member) ?? true }
}

/// A member's answer to an order.
public struct OrderAck: Codable, Equatable, Sendable {
    public enum Response: String, Codable, Sendable, CaseIterable {
        case seen, done, cannot
    }
    public var order: UUID
    public var response: Response
    public init(order: UUID, response: Response) {
        self.order = order
        self.response = response
    }
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

/// Why the squad may not see firing data right now. Holds only ever add to SafetyKit's
/// verdict (see `GroupGate`).
public enum Hold: Codable, Hashable, Sendable, CustomStringConvertible {
    case walkingOut
    case checkFire(by: String)
    case memberInFan(MemberID, name: String)
    case positionUnknown(MemberID, name: String)

    public var description: String {
        switch self {
        case .walkingOut: return "Cease fire: people are walking out."
        case let .checkFire(by): return "Check fire, called by \(by)."
        case let .memberInFan(_, name): return "\(name) is inside the firing fan."
        case let .positionUnknown(_, name): return "No recent position from \(name)."
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
        /// A member's answer to an order.
        case orderAck(OrderAck)
        /// A note pinned to the field: member → leader (passed on to observers), or phone → Theater.
        case fieldNote(FieldNote)
        /// A surveyed or loaded field: member → leader (to adopt), or phone → Theater (to register).
        case fieldSubmission(FieldSubmission)
        /// Phone → Theater: a file in chunks, then done.
        case fileOffer(FileOffer)
        case fileChunk(FileChunk)
        case fileDone(UUID)
        /// Phone → commander.
        case checkFire(CheckFire)

        // Commander → member's phone (and to observers: status and positions only)
        case welcome(Welcome)
        /// To a Theater station that joined as an observer.
        case observing(Squad)
        /// The squad's course, to an observer: the published boundary, holes, flags, firing points
        /// and hazards, for the site map. No firing data.
        case course(Course)
        case refused(String)
        case squadStatus(SquadStatus)
        case spotRequest(SpotRequest)
        case lockReceipt(LockReceipt)
        /// The squad leader's order, to the members it's for (and to observers, read-only).
        case order(Order)
        /// What the leader or the Theater did with a note, field or file.
        case receipt(Receipt)

        /// Commander → observers: members' positions.
        case positions(squad: SquadID, [MemberPosition])
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
