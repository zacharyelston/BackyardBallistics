import Foundation
import CoreGeo

/// The commander's device: the squad core (docs/SQUAD_CORE.md) running one mission. The core does
/// what every squad needs: join and rejoin, the roster, positions, orders, field notes, check fire,
/// observers and the holds. The mission (`GolfMission` for SpudGunGolf) does the rest. Every input
/// from a phone is untrusted data that this host gates and commits.
///
/// Pure state: `handle` and the commander's actions return the messages to send.
public struct SquadCore<M: Mission> {
    public internal(set) var squad: Squad
    public internal(set) var mission: M
    public let joinCode: String
    public internal(set) var revision: Int

    public private(set) var peers: [PeerID: MemberID] = [:]
    /// Theater stations watching the squad. They get status and positions; what they send is ignored.
    public private(set) var observers: Set<PeerID> = []
    public private(set) var positions: [MemberID: MemberPosition] = [:]
    /// The last thing that went wrong, for the commander's screen.
    public private(set) var lastProblem: String?
    /// Field notes from members, oldest first (passed on to observers as they arrive).
    public private(set) var notes: [FieldNote] = []
    /// Orders sent this session, oldest first, and each recipient's latest answer.
    public private(set) var orders: [Order] = []
    public private(set) var acks: [UUID: [MemberID: OrderAck.Response]] = [:]
    static var maxOrdersKept: Int { 100 }

    /// Check fire in force, from any member or this iPad. Only the commander lifts it.
    public private(set) var activeCheckFire: CheckFire?
    private var seenCheckFires: Set<UUID> = []

    public init(squad: Squad, mission: M, joinCode: String, revision: Int = 0) {
        self.squad = squad
        self.mission = mission
        self.joinCode = joinCode
        self.revision = revision
    }

    public var squadID: SquadID { squad.id }
    public var player: String { squad.name }

    /// What the core knows, for the mission.
    public var view: CoreView {
        CoreView(squad: squad, positions: positions, peers: peers, observers: observers, checkFire: activeCheckFire)
    }

    // MARK: Holds

    /// Everything holding this squad right now: the core's and the mission's. Holds only add
    /// (see `GroupGate`).
    public func holds(now: Date) -> Set<Hold> {
        let core = view
        return core.holds.union(mission.holds(core: core, now: now))
    }

    // MARK: Messages

    public mutating func handle(_ message: GroupMessage, from peer: PeerID, now: Date) -> [Outgoing] {
        guard message.protocolVersion == GroupProtocol.version else {
            return [Outgoing(to: peer, .refused("Protocol version \(message.protocolVersion); this iPad speaks \(GroupProtocol.version). Update the app."))]
        }
        if case let .hello(hello) = message.body {
            if hello.role == .contributor {
                return [Outgoing(to: peer, .refused("This is a squad's iPad. To send to the Theater host, use Send to Theater."))]
            }
            return join(hello, peer: peer, now: now)
        }
        if observers.contains(peer) {
            if case .bye = message.body { observers.remove(peer) }
            return []   // an observer can't act on the squad
        }
        guard let member = peers[peer] else { return [] }   // not joined: ignored

        switch message.body {
        case .bye:
            peers[peer] = nil
            return []
        case var .position(p):
            p.member = member
            positions[member] = p
            return view.observerPeers.map { Outgoing(to: $0, .positions(squad: squadID, [p])) }
        case var .fieldNote(n):
            n.author = squad.members.first { $0.id == member }?.name ?? n.author
            notes.append(n)
            if notes.count > 100 { notes.removeFirst(notes.count - 100) }
            let toObservers = view.observerPeers.map { Outgoing(to: $0, .fieldNote(n)) }
            return [Outgoing(to: peer, .receipt(Receipt(id: n.id, status: .stored, detail: "Sent to \(player)'s leader.")))] + toObservers
        case let .orderAck(a):
            // Only from someone the order was for.
            guard let o = orders.first(where: { $0.id == a.order }), o.isFor(member) else { return [] }
            acks[a.order, default: [:]][member] = a.response
            return []
        case let .checkFire(cf):
            return raiseCheckFire(cf, now: now)
        default:
            let core = view
            guard let step = mission.handle(message.body, from: member, peer: peer, core: core, now: now) else {
                return []   // commander messages from a phone, or nothing this squad plays: ignored
            }
            return finish(step, now: now)
        }
    }

    private mutating func join(_ hello: Hello, peer: PeerID, now: Date) -> [Outgoing] {
        guard hello.joinCode == joinCode else { return [Outgoing(to: peer, .refused("Wrong join code."))] }
        if hello.role == .observer {
            peers[peer] = nil
            observers.insert(peer)
            let known = positions.values.sorted { $0.time < $1.time }
            return [Outgoing(to: peer, .observing(squad))]
                + mission.observerWelcome(core: view).map { Outgoing(to: peer, $0) }
                + [Outgoing(to: peer, .squadStatus(status(now: now)))]
                + (known.isEmpty ? [] : [Outgoing(to: peer, .positions(squad: squadID, known))])
        }
        observers.remove(peer)
        let id: MemberID
        if let existing = squad.members.first(where: { $0.device == hello.device }) {
            id = existing.id
        } else {
            let m = Member(name: hello.name, device: hello.device, role: mission.role(forNewMemberOf: squad))
            squad.members.append(m)
            id = m.id
        }
        peers = peers.filter { $0.value != id }   // a rejoin replaces the old link
        peers[peer] = id
        // Orders for this member that it hasn't finished, so a rejoin (or a late joiner) has them.
        let open = orders.filter { $0.isFor(id) && acks[$0.id]?[id] != .done && acks[$0.id]?[id] != .cannot }.suffix(10)
        return [Outgoing(to: peer, .welcome(Welcome(member: id, squad: squad)))]
            + open.map { Outgoing(to: peer, .order($0)) } + changed(now: now)
    }

    // MARK: Commander's actions

    public mutating func setRole(_ member: MemberID, _ role: MemberRole, now: Date) -> [Outgoing] {
        guard let i = squad.members.firstIndex(where: { $0.id == member }) else { return [] }
        squad.members[i].role = role
        return changed(now: now)
    }

    /// Takes a member off the roster (gone home): the squad stops waiting for their position.
    public mutating func removeMember(_ member: MemberID, now: Date) -> [Outgoing] {
        squad.members.removeAll { $0.id == member }
        peers = peers.filter { $0.value != member }
        positions[member] = nil
        return changed(now: now)
    }

    /// Sends an order to some members (`to`), or to the whole squad (nil). Observers see it too.
    public mutating func sendOrder(_ kind: Order.Kind, text: String, at: GeoPoint? = nil, to: [MemberID]? = nil,
                                   now: Date) -> [Outgoing] {
        let roster = Set(squad.members.map(\.id))
        let targets = to.map { $0.filter(roster.contains) }
        if let targets, targets.isEmpty { return problem("Pick at least one member.") }
        let order = Order(kind: kind, text: text, at: at, to: targets, time: now)
        orders.append(order)
        if orders.count > Self.maxOrdersKept { orders.removeFirst(orders.count - Self.maxOrdersKept) }
        let members = peers.filter { order.isFor($0.value) }.map(\.key)
        return (members + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .order(order)) }
    }

    /// Who an order is for, by member.
    public func recipients(of order: Order) -> [Member] {
        squad.members.filter { order.isFor($0.id) }
    }

    /// Check fire called on this iPad.
    public mutating func callCheckFire(by: String, now: Date) -> [Outgoing] {
        raiseCheckFire(CheckFire(by: by), now: now)
    }

    /// Lifts check fire. The mission may still need the commander to confirm again (golf: downrange).
    public mutating func withdrawCheckFire(now: Date) -> [Outgoing] {
        guard activeCheckFire != nil else { return [] }
        activeCheckFire = nil
        return changed(now: now)
    }

    // MARK: Running the mission

    /// Runs one of the mission's actions with the core's view, then sends what it asks for.
    mutating func run(_ now: Date, _ action: (inout M, CoreView) -> MissionStep) -> [Outgoing] {
        let core = view
        let step = action(&mission, core)
        return finish(step, now: now)
    }

    private mutating func finish(_ step: MissionStep, now: Date) -> [Outgoing] {
        if step.clearsProblem { lastProblem = nil }
        if let p = step.problem { lastProblem = p }
        if step.changed { return step.out + changed(now: now) }
        if step.statusOnly { return step.out + statusToMembers(now: now) }
        return step.out
    }

    // MARK: Internals

    private mutating func raiseCheckFire(_ cf: CheckFire, now: Date) -> [Outgoing] {
        guard !seenCheckFires.contains(cf.id) else { return [] }
        seenCheckFires.insert(cf.id)
        if activeCheckFire == nil { activeCheckFire = cf }
        mission.checkFireRaised(core: view)
        return changed(now: now)
    }

    private mutating func problem(_ text: String) -> [Outgoing] {
        lastProblem = text
        return []
    }

    /// Bumps the revision and tells the members.
    private mutating func changed(now: Date) -> [Outgoing] {
        revision += 1
        return statusToMembers(now: now)
    }

    /// Status to every member and observer.
    private func statusToMembers(now: Date) -> [Outgoing] {
        let s = status(now: now)
        return (Array(peers.keys) + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .squadStatus(s)) }
    }

    /// What members see: the roster, the holds and the mission's part. No firing data.
    public func status(now: Date) -> SquadStatus {
        let core = view
        var s = SquadStatus(revision: revision, squad: squad, hole: nil, phase: nil, walkingOut: false, missions: 0,
                            rounds: [], roundInFlight: nil, total: 0, toPar: 0,
                            holds: holds(now: now).sorted { $0.description < $1.description })
        mission.fill(&s, core: core, now: now)
        return s
    }
}
