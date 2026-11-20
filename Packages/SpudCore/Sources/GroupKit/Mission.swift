import Foundation

/// A mission add-on to the squad core (docs/SQUAD_CORE.md). The core does what every squad needs:
/// join, roster, positions, orders, notes, check fire and holds. A mission adds its own messages,
/// state, holds and part of the status. Golf fire missions (`GolfMission`) are the first.
///
/// Holds only add: the core's holds and the mission's are unioned, and nothing a mission returns
/// can remove a core hold.
///
/// C1 keeps the wire as it is, so a mission still gets `GroupMessage.Body` cases. C2 gives
/// missions their own `.mission(id, version, payload)` body.
public protocol Mission {
    static var id: String { get }
    static var version: Int { get }

    /// A joined member's message the core doesn't handle. Nil when it isn't this mission's.
    mutating func handle(_ body: GroupMessage.Body, from member: MemberID, peer: PeerID,
                         core: CoreView, now: Date) -> MissionStep?
    /// This mission's holds. The core adds them to its own.
    func holds(core: CoreView, now: Date) -> Set<Hold>
    /// Someone called check fire. The core has already raised its hold.
    mutating func checkFireRaised(core: CoreView)
    /// The role a member gets on first joining.
    func role(forNewMemberOf squad: Squad) -> MemberRole
    /// Sent to an observer after `.observing`, before the first status.
    func observerWelcome(core: CoreView) -> [GroupMessage.Body]
    /// Fills this mission's part of the status. Never firing data.
    func fill(_ status: inout SquadStatus, core: CoreView, now: Date)
}

/// What the core knows, as a mission sees it. Read-only.
public struct CoreView {
    public let squad: Squad
    public let positions: [MemberID: MemberPosition]
    public let peers: [PeerID: MemberID]
    public let observers: Set<PeerID>
    public let checkFire: CheckFire?

    public var player: String { squad.name }
    public var squadID: SquadID { squad.id }

    /// The core's own holds.
    public var holds: Set<Hold> { checkFire.map { [.checkFire(by: $0.by)] } ?? [] }

    /// The link a member is on now, if any.
    public func peer(of member: MemberID) -> PeerID? {
        peers.first { $0.value == member }?.key
    }

    public func member(_ id: MemberID) -> Member? {
        squad.members.first { $0.id == id }
    }

    /// Every joined member's link, in a stable order.
    public var memberPeers: [PeerID] { peers.keys.sorted { $0.raw < $1.raw } }
    /// Every observer's link, in a stable order.
    public var observerPeers: [PeerID] { observers.sorted { $0.raw < $1.raw } }
}

/// What a mission's message or action did, for the core to finish.
public struct MissionStep {
    /// Sent first, in order.
    public var out: [Outgoing]
    /// The squad changed: the core bumps the revision and sends status to everyone.
    public var changed: Bool
    /// Status to everyone without a new revision.
    public var statusOnly: Bool
    /// Something went wrong, for the commander's screen.
    public var problem: String?
    /// The last problem is resolved.
    public var clearsProblem: Bool

    public init(_ out: [Outgoing] = [], changed: Bool = false, statusOnly: Bool = false,
                problem: String? = nil, clearsProblem: Bool = false) {
        self.out = out
        self.changed = changed
        self.statusOnly = statusOnly
        self.problem = problem
        self.clearsProblem = clearsProblem
    }

    public static let none = MissionStep()
    public static func changed(_ out: [Outgoing] = [], clearsProblem: Bool = false) -> MissionStep {
        MissionStep(out, changed: true, clearsProblem: clearsProblem)
    }
    public static func problem(_ text: String, _ out: [Outgoing] = []) -> MissionStep {
        MissionStep(out, problem: text)
    }
}
