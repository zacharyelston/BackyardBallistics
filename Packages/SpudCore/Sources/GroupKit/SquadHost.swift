import Foundation
import CoreGeo
import SafetyKit
import RangingKit
import CourseKit
import RoundKit

/// One step of a hole, so the hole can be rebuilt when the commander amends a spot.
public enum HoleEvent: Codable, Equatable, Sendable {
    case begin(lockedRange: Double, bearing: Double, heightDifference: Double, from: GeoPoint?)
    case record(Spot)
    case lost
    case cease(closest: Double?)
    case resume
    case advance(lockedRange: Double, bearing: Double, heightDifference: Double, from: GeoPoint?)

    var isRound: Bool {
        switch self {
        case .record, .lost: return true
        default: return false
        }
    }
}

/// The squad's round, as the commander's iPad keeps it. Codable, so it survives a relaunch.
public struct SquadRound: Codable, Equatable, Sendable {
    public var squad: Squad
    public var course: Course
    public var practice: Bool
    public var card: Scorecard
    public var hole: HolePlay?
    /// The current hole's steps, in order.
    public var events: [HoleEvent] = []
    /// Firing point index chosen for the current hole.
    public var firingPoint = 0
    public var downrange = DownrangeLog()
    /// Cease fire was called: people are, or may be, downrange until the hole moves on.
    public var walkingOut = false
    public var revision = 0

    public init(squad: Squad, course: Course, practice: Bool) {
        self.squad = squad
        self.course = course
        self.practice = practice
        self.card = Scorecard(course: course, player: squad.name, practice: practice, playerID: squad.id.raw)
    }

    public var currentHole: Hole? {
        guard let n = hole?.holeNumber ?? card.nextHole else { return nil }
        return course.holes.first { $0.number == n }
    }

    /// Rebuilds a hole from its steps.
    public static func replay(_ events: [HoleEvent], hole: Hole) throws -> HolePlay {
        var h = HolePlay(hole: hole)
        for e in events {
            switch e {
            case let .begin(r, b, dh, from): try h.begin(lockedRange: r, bearing: b, heightDifference: dh, from: from)
            case let .record(spot): try h.record(spot)
            case .lost: try h.recordLost()
            case let .cease(closest): try h.ceaseFire(closest: closest)
            case .resume: try h.resume()
            case let .advance(r, b, dh, from): try h.advance(lockedRange: r, bearing: b, heightDifference: dh, from: from)
            }
        }
        return h
    }
}

/// A lock a member sent, and what the commander did with it.
public struct ReceivedLock: Equatable, Sendable {
    public var report: LockReport
    public var member: MemberID
    public var status: LockReceipt.Status
}

public struct ReceivedSpot: Equatable, Sendable {
    public var report: SpotReport
    public var member: MemberID
}

/// The commander's iPad: hosts one squad. It's the squad's only firing display, so every input
/// from a phone is untrusted data that this host gates and commits.
///
/// Pure state: `handle` and the commander's actions return the messages to send.
public struct SquadHost {
    public private(set) var round: SquadRound
    public let joinCode: String
    /// A member whose spot (with a measured left/right) is committed without waiting for the commander.
    public var designatedSpotter: MemberID?

    public private(set) var peers: [PeerID: MemberID] = [:]
    /// Theater stations watching the squad. They get status and positions; what they send is ignored.
    public private(set) var observers: Set<PeerID> = []
    public private(set) var positions: [MemberID: MemberPosition] = [:]
    public private(set) var locks: [ReceivedLock] = []
    public private(set) var spotReports: [ReceivedSpot] = []
    public private(set) var roundInFlight: Int?
    public private(set) var match: MatchState?
    public private(set) var matchHost: PeerID?
    /// The last thing that went wrong, for the commander's screen.
    public private(set) var lastProblem: String?
    /// Field notes from members, oldest first (passed on to observers as they arrive).
    public private(set) var notes: [FieldNote] = []
    /// Fields members surveyed or loaded and sent in, waiting for the leader to adopt one.
    public private(set) var submissions: [FieldSubmission] = []
    private var submitters: [UUID: MemberID] = [:]
    /// Orders sent this session, oldest first, and each recipient's latest answer.
    public private(set) var orders: [Order] = []
    public private(set) var acks: [UUID: [MemberID: OrderAck.Response]] = [:]
    static let maxOrdersKept = 100
    /// Things that happened under a hold (a Fired while held), for the after-action log.
    public private(set) var incidents: [String] = []

    private var matchSeenAt: Date?
    /// Check fires raised through this squad that the match host hasn't acknowledged yet.
    private var pendingCheckFires: [CheckFire] = []
    private var seenCheckFires: Set<UUID> = []

    /// The match host's heartbeat older than this holds the squad.
    public static let matchHostTimeout: TimeInterval = 5
    static let maxLocksKept = 50

    public init(squad: Squad, course: Course, practice: Bool, joinCode: String) {
        self.init(round: SquadRound(squad: squad, course: course, practice: practice), joinCode: joinCode)
    }

    /// Resumes from a saved round. Links and positions start empty; phones rejoin.
    public init(round: SquadRound, joinCode: String) {
        self.round = round
        self.joinCode = joinCode
    }

    public var squadID: SquadID { round.squad.id }
    public var player: String { round.squad.name }
    public var isOurTurn: Bool { match?.turn?.squad == squadID }

    // MARK: Holds and the firing display

    /// Everything holding this squad right now. Holds only add (see `GroupGate`).
    public func holds(now: Date) -> Set<Hold> {
        var h = Set(match?.holds ?? [])
        if let seen = matchSeenAt {
            if now.timeIntervalSince(seen) > Self.matchHostTimeout { h.insert(.matchHostLost) }
        } else {
            h.insert(.noMatch)
        }
        if match?.turn?.squad != squadID { h.insert(.notYourTurn) }
        for cf in pendingCheckFires { h.insert(.checkFire(by: cf.by)) }
        if round.walkingOut || round.hole?.phase == .ceased { h.insert(.walkingOut(squadID)) }
        return h
    }

    /// The only path from a solution to the commander's screen: SafetyKit's `clearSolution` first,
    /// then this squad's holds.
    public func firingDisplay<S>(_ verdict: Result<Cleared<S>, SafetyBlock>, now: Date) -> FiringDisplay<S> {
        GroupGate.display(verdict, holds: holds(now: now))
    }

    // MARK: Messages

    public mutating func handle(_ message: GroupMessage, from peer: PeerID, now: Date) -> [Outgoing] {
        guard message.protocolVersion == GroupProtocol.version else {
            return [Outgoing(to: peer, .refused("Protocol version \(message.protocolVersion); this iPad speaks \(GroupProtocol.version). Update the app."))]
        }
        if peer == matchHost {
            if case let .matchState(state) = message.body { return applyMatch(state, now: now) }
            return []
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
            let toObservers = observers.sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .positions(squad: squadID, [p])) }
            return (matchHost.map { [Outgoing(to: $0, .positions(squad: squadID, [p]))] } ?? []) + toObservers
        case let .lock(report):
            locks.append(ReceivedLock(report: report, member: member, status: .received))
            if locks.count > Self.maxLocksKept { locks.removeFirst(locks.count - Self.maxLocksKept) }
            return [Outgoing(to: peer, .lockReceipt(LockReceipt(lock: report.id, status: .received, reasons: [])))]
        case let .spot(report):
            return receiveSpot(report, from: member, now: now)
        case let .fired(f):
            return fired(f, by: member, now: now)
        case var .fieldNote(n):
            n.author = round.squad.members.first { $0.id == member }?.name ?? n.author
            notes.append(n)
            if notes.count > 100 { notes.removeFirst(notes.count - 100) }
            let toObservers = observers.sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .fieldNote(n)) }
            return [Outgoing(to: peer, .receipt(Receipt(id: n.id, status: .stored, detail: "Sent to \(player)'s leader.")))] + toObservers
        case var .fieldSubmission(f):
            f.author = round.squad.members.first { $0.id == member }?.name ?? f.author
            let errors = CourseValidator.blockingProblems(for: f.course)
            guard errors.isEmpty else {
                return [Outgoing(to: peer, .receipt(Receipt(id: f.id, status: .refused,
                                                            detail: errors.prefix(3).map(\.description).joined(separator: " "))))]
            }
            submissions.removeAll { $0.id == f.id }
            submissions.append(f)
            submitters[f.id] = member
            if submissions.count > 20 { submissions.removeFirst(submissions.count - 20) }
            let practice = CourseValidator.isPracticeOnly(f.course) ? " It's practice only." : ""
            return [Outgoing(to: peer, .receipt(Receipt(id: f.id, status: .received, detail: "Waiting for the leader to adopt it." + practice)))]
        case let .orderAck(a):
            // Only from someone the order was for.
            guard let o = orders.first(where: { $0.id == a.order }), o.isFor(member) else { return [] }
            acks[a.order, default: [:]][member] = a.response
            return []
        case let .checkFire(cf):
            return raiseCheckFire(cf, now: now)
        default:
            return []   // commander and match messages from a phone are ignored
        }
    }

    private mutating func join(_ hello: Hello, peer: PeerID, now: Date) -> [Outgoing] {
        guard hello.joinCode == joinCode else { return [Outgoing(to: peer, .refused("Wrong join code."))] }
        if hello.role == .observer {
            peers[peer] = nil
            observers.insert(peer)
            let known = positions.values.sorted { $0.time < $1.time }
            return [Outgoing(to: peer, .observing(round.squad)),
                    Outgoing(to: peer, .course(round.course)),
                    Outgoing(to: peer, .squadStatus(status(now: now)))]
                + (known.isEmpty ? [] : [Outgoing(to: peer, .positions(squad: squadID, known))])
        }
        observers.remove(peer)
        let id: MemberID
        if let existing = round.squad.members.first(where: { $0.device == hello.device }) {
            id = existing.id
        } else {
            let gunner = !round.squad.members.contains { $0.role == .gunner }
            let m = Member(name: hello.name, device: hello.device, role: gunner ? .gunner : .member)
            round.squad.members.append(m)
            id = m.id
        }
        peers = peers.filter { $0.value != id }   // a rejoin replaces the old link
        peers[peer] = id
        // Orders for this member that it hasn't finished, so a rejoin (or a late joiner) has them.
        let open = orders.filter { $0.isFor(id) && acks[$0.id]?[id] != .done && acks[$0.id]?[id] != .cannot }.suffix(10)
        return [Outgoing(to: peer, .welcome(Welcome(member: id, squad: round.squad)))]
            + open.map { Outgoing(to: peer, .order($0)) } + changed(now: now)
    }

    private mutating func applyMatch(_ state: MatchState, now: Date) -> [Outgoing] {
        let newer = state.revision != match?.revision
        match = state
        matchSeenAt = now
        let known = Set(state.knownCheckFires)
        pendingCheckFires.removeAll { known.contains($0.id) }
        // A check fire raised anywhere withdraws this squad's downrange confirmation.
        for id in known where !seenCheckFires.contains(id) {
            seenCheckFires.insert(id)
            revokeDownrange()
        }
        return newer ? statusToMembers(now: now) : []
    }

    // MARK: Commander's actions

    /// Links to the match host (which may be this iPad, over the loopback).
    public mutating func connectMatch(_ peer: PeerID, joinCode: String, now: Date) -> [Outgoing] {
        matchHost = peer
        let course = round.course
        return [Outgoing(to: peer, .joinMatch(JoinMatch(squad: squadID, name: player, joinCode: joinCode,
                                                        courseID: course.id, courseVersion: course.version,
                                                        courseHash: CourseFingerprint.hash(course)))),
                Outgoing(to: peer, .squadReport(report()))]
    }

    public mutating func setRole(_ member: MemberID, _ role: MemberRole, now: Date) -> [Outgoing] {
        guard let i = round.squad.members.firstIndex(where: { $0.id == member }) else { return [] }
        round.squad.members[i].role = role
        return changed(now: now)
    }

    /// Takes a member off the roster (gone home): the match stops waiting for their position.
    public mutating func removeMember(_ member: MemberID, now: Date) -> [Outgoing] {
        round.squad.members.removeAll { $0.id == member }
        peers = peers.filter { $0.value != member }
        positions[member] = nil
        return changed(now: now)
    }

    /// Opens the next unfinished hole.
    public mutating func startNextHole(firingPoint: Int = 0, now: Date) -> [Outgoing] {
        guard round.hole == nil || round.hole?.phase == .finished,
              let n = round.card.nextHole, let hole = round.course.holes.first(where: { $0.number == n }) else { return [] }
        round.hole = HolePlay(hole: hole)
        round.events = []
        round.firingPoint = min(max(0, firingPoint), hole.firingPoints.count - 1)
        round.walkingOut = false
        roundInFlight = nil
        spotReports = []
        return changed(now: now)
    }

    /// The commander's own look downrange. No message can do this.
    public mutating func confirmDownrange(now: Date) -> [Outgoing] {
        guard let n = round.hole?.holeNumber else { return [] }
        round.downrange.confirm(player: player, hole: n)
        return changed(now: now)
    }

    public func isDownrangeConfirmed() -> Bool {
        guard let n = round.hole?.holeNumber else { return false }
        return round.downrange.isConfirmed(player: player, hole: n)
    }

    /// Uses a member's lock for its purpose, after the flag check on this iPad's own course.
    public mutating func useLock(_ id: UUID, now: Date) -> [Outgoing] {
        guard let i = locks.firstIndex(where: { $0.report.id == id }) else { return problem("No such lock.", now: now) }
        let received = locks[i]
        // The member may have dropped out since; then there's no one to tell.
        let peer = peers.first(where: { $0.value == received.member })?.key
        func receipt(_ s: LockReceipt.Status, _ reasons: [String]) -> [Outgoing] {
            peer.map { [Outgoing(to: $0, .lockReceipt(LockReceipt(lock: id, status: s, reasons: reasons)))] } ?? []
        }
        guard let holeInfo = round.currentHole, round.hole != nil else {
            locks[i].status = .refused
            return receipt(.refused, ["No hole in play."]) + problem("No hole in play.", now: now)
        }
        let lock = received.report.lock
        // Recompute with this hole's pole height, in case the phone had another one set.
        let reticle = ReticleRange(focalPixels: lock.reticle.focalPixels, poleHeight: holeInfo.flag.poleHeightM,
                                   angleBelowLevel: lock.reticle.angleBelowLevel)
        let range = reticle.range(linePixels: lock.linePixels) ?? lock.range
        let b = Geo.radians(lock.bearing)
        let cleared = Safety.clearRange(range, lie: lock.location, east: range * sin(b), north: range * cos(b),
                                        flag: holeInfo.flag.position)
        guard case let .success(r) = cleared else {
            let reasons = cleared.failureReasons.map(\.description)
            locks[i].status = .refused
            return receipt(.refused, reasons) + problem("Lock refused: " + reasons.joined(separator: " "), now: now)
        }
        let d = r.value
        let dh = ReticleRange.heightDifference(range: d, cameraHeight: lock.cameraHeight, angleBelowLevel: lock.angleBelowLevel)
        let event: HoleEvent?
        switch received.report.purpose {
        case .initial: event = .begin(lockedRange: d, bearing: lock.bearing, heightDifference: dh, from: lock.location)
        case .nextMission: event = .advance(lockedRange: d, bearing: lock.bearing, heightDifference: dh, from: lock.location)
        case .verify: event = .cease(closest: d)
        case .observation: event = nil
        }
        if let event {
            if let error = apply(event) {
                locks[i].status = .refused
                return receipt(.refused, [error]) + problem(error, now: now)
            }
            if case .advance = event {
                // A new firing position: whoever walked out is now behind it, but the commander looks again.
                round.walkingOut = false
                revokeDownrange()
            }
        }
        locks[i].status = .used
        lastProblem = nil
        return receipt(.used, []) + changed(now: now)
    }

    /// Verifies with a taped distance, or none (nothing found: scored from the firing position).
    public mutating func verify(closest: Double?, now: Date) -> [Outgoing] {
        if let error = apply(.cease(closest: closest)) { return problem(error, now: now) }
        return changed(now: now)
    }

    /// Cease fire: the squad walks out. Holds every squad until the hole moves on.
    public mutating func ceaseFire(now: Date) -> [Outgoing] {
        guard round.hole?.phase == .firing else { return problem("Not firing.", now: now) }
        round.walkingOut = true
        return changed(now: now)
    }

    /// Back to the same firing position. Everyone was downrange, so the commander confirms again.
    public mutating func resume(now: Date) -> [Outgoing] {
        if let error = apply(.resume) { return problem(error, now: now) }
        round.walkingOut = false
        revokeDownrange()
        return changed(now: now)
    }

    public mutating func finish(now: Date) -> [Outgoing] {
        guard var h = round.hole else { return [] }
        do { try h.finish() } catch { return problem(String(describing: error), now: now) }
        round.hole = h
        round.card.record(h)
        round.walkingOut = false
        roundInFlight = nil
        return changed(now: now)
    }

    /// The commander calls Fired on the gunner's behalf.
    public mutating func fired(now: Date) -> [Outgoing] {
        guard let h = round.hole, let m = h.mission else { return [] }
        return fired(FiredReport(hole: h.holeNumber, mission: m.number, round: h.roundsFired + 1), by: nil, now: now)
    }

    /// Commits a spot: the call from one member's report and the left/right from another's (or the same).
    public mutating func commit(callFrom: MemberID, lateralFrom: MemberID?, now: Date) -> [Outgoing] {
        guard let c = spotReports.first(where: { $0.member == callFrom }) else { return problem("No spot from that member.", now: now) }
        let lateral = lateralFrom.flatMap { m in spotReports.first { $0.member == m }?.report.lateral } ?? c.report.lateral ?? 0
        return commit(Spot(call: c.report.call, lateral: lateral), now: now)
    }

    public mutating func commit(_ spot: Spot, now: Date) -> [Outgoing] {
        guard roundInFlight != nil else { return problem("No round in flight.", now: now) }
        if let error = apply(.record(spot)) { return problem(error, now: now) }
        roundInFlight = nil
        spotReports = []
        return changed(now: now)
    }

    public mutating func commitLost(now: Date) -> [Outgoing] {
        guard roundInFlight != nil else { return problem("No round in flight.", now: now) }
        if let error = apply(.lost) { return problem(error, now: now) }
        roundInFlight = nil
        spotReports = []
        return changed(now: now)
    }

    /// Corrects round `number`'s spot (nil = lost) and replays the hole. Fire control's later
    /// corrections change with it.
    public mutating func amend(round number: Int, to spot: Spot?, now: Date) -> [Outgoing] {
        guard let hole = round.currentHole, round.hole?.phase != .finished else { return problem("No hole to amend.", now: now) }
        var events = round.events
        guard let i = events.indices.filter({ events[$0].isRound }).dropFirst(number - 1).first, number >= 1 else {
            return problem("No round \(number).", now: now)
        }
        events[i] = spot.map { .record($0) } ?? .lost
        do {
            round.hole = try SquadRound.replay(events, hole: hole)
            round.events = events
        } catch {
            return problem("Can't amend: \(error)", now: now)
        }
        return changed(now: now)
    }

    /// Sends an order to some members (`to`), or to the whole squad (nil). Observers see it too.
    public mutating func sendOrder(_ kind: Order.Kind, text: String, at: GeoPoint? = nil, to: [MemberID]? = nil,
                                   now: Date) -> [Outgoing] {
        let roster = Set(round.squad.members.map(\.id))
        let targets = to.map { $0.filter(roster.contains) }
        if let targets, targets.isEmpty { return problem("Pick at least one member.", now: now) }
        let order = Order(kind: kind, text: text, at: at, to: targets, time: now)
        orders.append(order)
        if orders.count > Self.maxOrdersKept { orders.removeFirst(orders.count - Self.maxOrdersKept) }
        let members = peers.filter { order.isFor($0.value) }.map(\.key)
        return (members + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .order(order)) }
    }

    /// Switches the squad to a field a member sent in. Only between holes and outside a started
    /// match: the squad keeps its members and starts a fresh card on the new field. Observers (the
    /// Theater) get the new course, so it's registered there too.
    public mutating func adoptField(_ submission: UUID, now: Date) -> [Outgoing] {
        guard let f = submissions.first(where: { $0.id == submission }) else { return problem("No such field.", now: now) }
        if let h = round.hole, h.phase != .finished { return problem("Finish or end hole \(h.holeNumber) first.", now: now) }
        if round.walkingOut { return problem("People are walking out. Adopt the field once they're back.", now: now) }
        if match?.started == true { return problem("The match is under way on \(round.course.name).", now: now) }
        // A field that's practice only (a fan leaving the boundary, a firing point out of range) puts
        // the squad in practice: simulated rounds only.
        let practiceOnly = CourseValidator.isPracticeOnly(f.course)
        var next = SquadRound(squad: round.squad, course: f.course, practice: round.practice || practiceOnly)
        next.revision = round.revision
        round = next
        roundInFlight = nil
        spotReports = []
        locks = []
        submissions.removeAll { $0.id == submission }
        let author = submitters.removeValue(forKey: submission).flatMap { m in peers.first { $0.value == m }?.key }
        let receipt = author.map { [Outgoing(to: $0, .receipt(Receipt(id: f.id, status: .stored,
                                                                        detail: "\(player) is playing \(f.course.name) now" + (practiceOnly ? ", in practice." : "."))))] } ?? []
        let toObservers = observers.sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .course(f.course)) }
        return receipt + toObservers + changed(now: now)
    }

    /// Drops a field a member sent in.
    public mutating func declineField(_ submission: UUID, now: Date) -> [Outgoing] {
        submissions.removeAll { $0.id == submission }
        let author = submitters.removeValue(forKey: submission).flatMap { m in peers.first { $0.value == m }?.key }
        return author.map { [Outgoing(to: $0, .receipt(Receipt(id: submission, status: .refused,
                                                                  detail: "The leader passed on this field.")))] } ?? []
    }

    /// Who an order is for, by member.
    public func recipients(of order: Order) -> [Member] {
        round.squad.members.filter { order.isFor($0.id) }
    }

    /// Check fire called on this iPad.
    public mutating func callCheckFire(by: String, now: Date) -> [Outgoing] {
        raiseCheckFire(CheckFire(by: by), now: now)
    }

    // MARK: Internals

    private mutating func receiveSpot(_ r: SpotReport, from member: MemberID, now: Date) -> [Outgoing] {
        guard let n = roundInFlight, let h = round.hole, r.round == n, r.hole == h.holeNumber,
              r.mission == h.mission?.number else { return [] }   // not the round in flight: ignored
        spotReports.removeAll { $0.member == member }
        spotReports.append(ReceivedSpot(report: r, member: member))
        if member == designatedSpotter, let lateral = r.lateral {
            return commit(Spot(call: r.call, lateral: lateral), now: now)
        }
        return statusToMembers(now: now)
    }

    private mutating func fired(_ f: FiredReport, by member: MemberID?, now: Date) -> [Outgoing] {
        if let member {
            let hasGunner = round.squad.members.contains { $0.role == .gunner }
            let isGunner = round.squad.members.first { $0.id == member }?.role == .gunner
            guard !hasGunner || isGunner else { return [] }
        }
        guard let h = round.hole, h.phase == .firing, !round.walkingOut, roundInFlight == nil, !h.atRoundLimit,
              let m = h.mission, f.hole == h.holeNumber, f.mission == m.number, f.round == h.roundsFired + 1 else { return [] }
        let held = holds(now: now)
        if !held.isEmpty {
            incidents.append("Round \(f.round) on hole \(f.hole) reported fired under: " +
                             held.map(\.description).sorted().joined(separator: " "))
        }
        roundInFlight = f.round
        spotReports = []
        let ask = SpotRequest(hole: f.hole, mission: f.mission, round: f.round)
        return peers.keys.sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .spotRequest(ask)) } + changed(now: now)
    }

    private mutating func raiseCheckFire(_ cf: CheckFire, now: Date) -> [Outgoing] {
        guard !seenCheckFires.contains(cf.id) else { return [] }
        seenCheckFires.insert(cf.id)
        pendingCheckFires.append(cf)
        revokeDownrange()
        let forward = matchHost.map { [Outgoing(to: $0, .checkFire(cf))] } ?? []
        return forward + changed(now: now)
    }

    private mutating func revokeDownrange() {
        guard let n = round.hole?.holeNumber else { return }
        round.downrange.revoke(player: player, hole: n)
    }

    /// Applies one step to the hole; returns an error message instead of throwing.
    private mutating func apply(_ event: HoleEvent) -> String? {
        guard let hole = round.hole else { return "No hole in play." }
        var h = hole
        do {
            switch event {
            case let .begin(r, b, dh, from): try h.begin(lockedRange: r, bearing: b, heightDifference: dh, from: from)
            case let .record(spot): try h.record(spot)
            case .lost: try h.recordLost()
            case let .cease(closest): try h.ceaseFire(closest: closest)
            case .resume: try h.resume()
            case let .advance(r, b, dh, from): try h.advance(lockedRange: r, bearing: b, heightDifference: dh, from: from)
            }
        } catch {
            return "That doesn't fit the hole right now (\(error))."
        }
        round.hole = h
        round.events.append(event)
        return nil
    }

    private mutating func problem(_ text: String, now: Date) -> [Outgoing] {
        lastProblem = text
        return []
    }

    /// Bumps the revision and tells the members and the match host.
    private mutating func changed(now: Date) -> [Outgoing] {
        round.revision += 1
        let toMatch = matchHost.map { [Outgoing(to: $0, .squadReport(report()))] } ?? []
        return statusToMembers(now: now) + toMatch
    }

    /// Status to every member and observer.
    private func statusToMembers(now: Date) -> [Outgoing] {
        let s = status(now: now)
        return (Array(peers.keys) + Array(observers)).sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .squadStatus(s)) }
    }

    /// What members see: no firing data.
    public func status(now: Date) -> SquadStatus {
        let h = round.hole
        let rounds = (h?.rounds ?? []).map {
            RoundSummary(number: $0.number, mission: $0.mission, call: $0.spot?.call, lateral: $0.spot?.lateral,
                         addDrop: $0.addDrop, rightLeft: $0.rightLeft, lost: $0.lost)
        }
        return SquadStatus(revision: round.revision, squad: round.squad, hole: h?.holeNumber, phase: h?.phase,
                           walkingOut: round.walkingOut, missions: h?.missions.count ?? 0, rounds: rounds,
                           roundInFlight: roundInFlight, total: round.card.total, toPar: round.card.toPar,
                           yourTurn: isOurTurn, holds: holds(now: now).sorted { $0.description < $1.description })
    }

    /// What the match host needs: phase, the active fan, walking out, finished scores.
    public func report() -> SquadReport {
        var fan: Fan?
        if let h = round.hole, let hole = round.currentHole, !round.walkingOut, h.phase == .setup || h.phase == .firing {
            let origin = h.mission?.from ?? hole.firingPoints[min(round.firingPoint, hole.firingPoints.count - 1)]
            fan = Fan(origin: origin, bearing: Geo.bearing(from: origin, to: hole.flag.position))
        }
        var scores: [Int: Double] = [:]
        for s in round.card.holes { if let v = s.score { scores[s.number] = v } }
        return SquadReport(squad: squadID, revision: round.revision, members: round.squad.members,
                           hole: round.hole?.holeNumber, phase: round.hole?.phase, walkingOut: round.walkingOut,
                           fan: fan, scores: scores)
    }
}

extension Result where Failure == SafetyBlock {
    var failureReasons: [SafetyReason] {
        if case let .failure(b) = self { return b.reasons }
        return []
    }
}
