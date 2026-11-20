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


/// Golf fire missions as a squad mission: the course and fields sent in, range locks, Fired, spot
/// requests and reports, the hole and its rounds, the firing fan and its holds. Firing data never
/// leaves the iPad: this mission works out holds and status, and `firingDisplay` gates solutions.
public struct GolfMission: Mission {
    public static let id = "golf.firemission"
    public static let version = 1

    // The hole as it's played. Saved with the squad (see `SquadRound`).
    public internal(set) var course: Course
    public internal(set) var practice: Bool
    public internal(set) var card: Scorecard
    public internal(set) var hole: HolePlay?
    public internal(set) var events: [HoleEvent] = []
    public internal(set) var firingPoint = 0
    public internal(set) var downrange = DownrangeLog()
    public internal(set) var walkingOut = false

    // This session only.
    public internal(set) var locks: [ReceivedLock] = []
    public internal(set) var spotReports: [ReceivedSpot] = []
    public internal(set) var roundInFlight: Int?
    public internal(set) var submissions: [FieldSubmission] = []
    var submitters: [UUID: MemberID] = [:]
    /// A member whose spot (with a measured left/right) is committed without waiting for the commander.
    public var designatedSpotter: MemberID?
    /// Things that happened under a hold (a Fired while held), for the after-action log.
    public internal(set) var incidents: [String] = []

    /// A member's position older than this counts as unknown, which holds the squad while a hole is live.
    public static let positionTimeout: TimeInterval = 15
    /// Within this of the fan's origin (or the GPS accuracy, if larger), a member is at the firing
    /// point, behind the fan, not in it.
    public static let firingPointRadius = 5.0
    static let maxLocksKept = 50

    public init(squad: Squad, course: Course, practice: Bool) {
        self.course = course
        self.practice = practice
        self.card = Scorecard(course: course, player: squad.name, practice: practice, playerID: squad.id.raw)
    }

    init(round: SquadRound) {
        course = round.course
        practice = round.practice
        card = round.card
        hole = round.hole
        events = round.events
        firingPoint = round.firingPoint
        downrange = round.downrange
        walkingOut = round.walkingOut
    }

    public var currentHole: Hole? {
        guard let n = hole?.holeNumber ?? card.nextHole else { return nil }
        return course.holes.first { $0.number == n }
    }

    // MARK: Mission

    public mutating func handle(_ body: GroupMessage.Body, from member: MemberID, peer: PeerID,
                                core: CoreView, now: Date) -> MissionStep? {
        switch body {
        case let .lock(report):
            locks.append(ReceivedLock(report: report, member: member, status: .received))
            if locks.count > Self.maxLocksKept { locks.removeFirst(locks.count - Self.maxLocksKept) }
            return MissionStep([Outgoing(to: peer, .lockReceipt(LockReceipt(lock: report.id, status: .received, reasons: [])))])
        case let .spot(report):
            return receiveSpot(report, from: member, core: core, now: now)
        case let .fired(f):
            return fired(f, by: member, core: core, now: now)
        case var .fieldSubmission(f):
            f.author = core.member(member)?.name ?? f.author
            let errors = CourseValidator.blockingProblems(for: f.course)
            guard errors.isEmpty else {
                return MissionStep([Outgoing(to: peer, .receipt(Receipt(id: f.id, status: .refused,
                                                                        detail: errors.prefix(3).map(\.description).joined(separator: " "))))])
            }
            submissions.removeAll { $0.id == f.id }
            submissions.append(f)
            submitters[f.id] = member
            if submissions.count > 20 { submissions.removeFirst(submissions.count - 20) }
            let practice = CourseValidator.isPracticeOnly(f.course) ? " It's practice only." : ""
            return MissionStep([Outgoing(to: peer, .receipt(Receipt(id: f.id, status: .received, detail: "Waiting for the leader to adopt it." + practice)))])
        default:
            return nil
        }
    }

    /// The squad's own field: nobody shoots while someone may be out there.
    public func holds(core: CoreView, now: Date) -> Set<Hold> {
        var h: Set<Hold> = []
        if walkingOut || hole?.phase == .ceased { h.insert(.walkingOut) }
        if let fan = activeFan() {
            for m in core.squad.members {
                guard let p = core.positions[m.id], now.timeIntervalSince(p.time) <= Self.positionTimeout else {
                    h.insert(.positionUnknown(m.id, name: m.name))
                    continue
                }
                if Self.inFan(p, fan) { h.insert(.memberInFan(m.id, name: m.name)) }
            }
        }
        return h
    }

    /// Check fire takes back the commander's look downrange.
    public mutating func checkFireRaised(core: CoreView) {
        revokeDownrange(player: core.player)
    }

    /// The first member to join is the gunner.
    public func role(forNewMemberOf squad: Squad) -> MemberRole {
        squad.members.contains { $0.role == .gunner } ? .member : .gunner
    }

    public func observerWelcome(core: CoreView) -> [GroupMessage.Body] {
        [.course(course)]
    }

    public func fill(_ s: inout SquadStatus, core: CoreView, now: Date) {
        s.hole = hole?.holeNumber
        s.phase = hole?.phase
        s.walkingOut = walkingOut
        s.missions = hole?.missions.count ?? 0
        s.rounds = (hole?.rounds ?? []).map {
            RoundSummary(number: $0.number, mission: $0.mission, call: $0.spot?.call, lateral: $0.spot?.lateral,
                         addDrop: $0.addDrop, rightLeft: $0.rightLeft, lost: $0.lost)
        }
        s.roundInFlight = roundInFlight
        s.total = card.total
        s.toPar = card.toPar
    }

    // MARK: The commander's actions

    mutating func startNextHole(firingPoint: Int, core: CoreView, now: Date) -> MissionStep {
        guard hole == nil || hole?.phase == .finished,
              let n = card.nextHole, let next = course.holes.first(where: { $0.number == n }) else { return .none }
        hole = HolePlay(hole: next)
        events = []
        self.firingPoint = min(max(0, firingPoint), next.firingPoints.count - 1)
        walkingOut = false
        roundInFlight = nil
        spotReports = []
        return .changed()
    }

    mutating func confirmDownrange(core: CoreView) -> MissionStep {
        guard let n = hole?.holeNumber else { return .none }
        downrange.confirm(player: core.player, hole: n)
        return .changed()
    }

    func isDownrangeConfirmed(player: String) -> Bool {
        guard let n = hole?.holeNumber else { return false }
        return downrange.isConfirmed(player: player, hole: n)
    }

    mutating func useLock(_ id: UUID, core: CoreView, now: Date) -> MissionStep {
        guard let i = locks.firstIndex(where: { $0.report.id == id }) else { return .problem("No such lock.") }
        let received = locks[i]
        // The member may have dropped out since; then there's no one to tell.
        let peer = core.peer(of: received.member)
        func receipt(_ s: LockReceipt.Status, _ reasons: [String]) -> [Outgoing] {
            peer.map { [Outgoing(to: $0, .lockReceipt(LockReceipt(lock: id, status: s, reasons: reasons)))] } ?? []
        }
        guard let holeInfo = currentHole, let play = hole else {
            locks[i].status = .refused
            return .problem("No hole in play.", receipt(.refused, ["No hole in play."]))
        }
        let lock = received.report.lock
        // The pole this lock ranged: the next leg's target for a new mission, the current one to
        // verify. On holes with layups that's a layup marker until the last leg.
        let target = Self.target(for: received.report.purpose, hole: holeInfo, play: play)
        // Recompute with that pole's height, in case the phone had another one set.
        let reticle = ReticleRange(focalPixels: lock.reticle.focalPixels, poleHeight: target.poleHeightM,
                                   angleBelowLevel: lock.reticle.angleBelowLevel)
        let range = reticle.range(linePixels: lock.linePixels) ?? lock.range
        let b = Geo.radians(lock.bearing)
        let cleared = Safety.clearRange(range, lie: lock.location, east: range * sin(b), north: range * cos(b),
                                        flag: target.position)
        guard case let .success(r) = cleared else {
            let reasons = cleared.failureReasons.map(\.description)
            locks[i].status = .refused
            return .problem("Lock refused: " + reasons.joined(separator: " "), receipt(.refused, reasons))
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
                return .problem(error, receipt(.refused, [error]))
            }
            if case .advance = event {
                // A new firing position: whoever walked out is now behind it, but the commander looks again.
                walkingOut = false
                revokeDownrange(player: core.player)
            }
        }
        locks[i].status = .used
        return .changed(receipt(.used, []), clearsProblem: true)
    }

    mutating func verify(closest: Double?) -> MissionStep {
        if let error = apply(.cease(closest: closest)) { return .problem(error) }
        return .changed()
    }

    mutating func ceaseFire() -> MissionStep {
        guard hole?.phase == .firing else { return .problem("Not firing.") }
        walkingOut = true
        return .changed()
    }

    mutating func resume(core: CoreView) -> MissionStep {
        if let error = apply(.resume) { return .problem(error) }
        walkingOut = false
        revokeDownrange(player: core.player)
        return .changed()
    }

    mutating func finish() -> MissionStep {
        guard var h = hole else { return .none }
        do { try h.finish() } catch { return .problem(String(describing: error)) }
        hole = h
        card.record(h)
        walkingOut = false
        roundInFlight = nil
        return .changed()
    }

    mutating func firedByCommander(core: CoreView, now: Date) -> MissionStep {
        guard let h = hole, let m = h.mission else { return .none }
        return fired(FiredReport(hole: h.holeNumber, mission: m.number, round: h.roundsFired + 1), by: nil, core: core, now: now)
    }

    mutating func commit(callFrom: MemberID, lateralFrom: MemberID?) -> MissionStep {
        guard let c = spotReports.first(where: { $0.member == callFrom }) else { return .problem("No spot from that member.") }
        let lateral = lateralFrom.flatMap { m in spotReports.first { $0.member == m }?.report.lateral } ?? c.report.lateral ?? 0
        return commit(Spot(call: c.report.call, lateral: lateral))
    }

    mutating func commit(_ spot: Spot) -> MissionStep {
        guard roundInFlight != nil else { return .problem("No round in flight.") }
        if let error = apply(.record(spot)) { return .problem(error) }
        roundInFlight = nil
        spotReports = []
        return .changed()
    }

    mutating func commitLost() -> MissionStep {
        guard roundInFlight != nil else { return .problem("No round in flight.") }
        if let error = apply(.lost) { return .problem(error) }
        roundInFlight = nil
        spotReports = []
        return .changed()
    }

    mutating func amend(round number: Int, to spot: Spot?) -> MissionStep {
        guard let info = currentHole, hole?.phase != .finished else { return .problem("No hole to amend.") }
        var steps = events
        guard let i = steps.indices.filter({ steps[$0].isRound }).dropFirst(number - 1).first, number >= 1 else {
            return .problem("No round \(number).")
        }
        steps[i] = spot.map { .record($0) } ?? .lost
        do {
            hole = try SquadRound.replay(steps, hole: info)
            events = steps
        } catch {
            return .problem("Can't amend: \(error)")
        }
        return .changed()
    }

    mutating func adoptField(_ submission: UUID, squad: Squad, core: CoreView) -> MissionStep {
        guard let f = submissions.first(where: { $0.id == submission }) else { return .problem("No such field.") }
        if let h = hole, h.phase != .finished { return .problem("Finish or end hole \(h.holeNumber) first.") }
        if walkingOut { return .problem("People are walking out. Adopt the field once they're back.") }
        // A field that's practice only (a fan leaving the boundary, a firing point out of range) puts
        // the squad in practice: simulated rounds only.
        let practiceOnly = CourseValidator.isPracticeOnly(f.course)
        let author = submitters[submission].flatMap { core.peer(of: $0) }
        var next = GolfMission(squad: squad, course: f.course, practice: practice || practiceOnly)
        next.submissions = submissions.filter { $0.id != submission }
        next.submitters = submitters.filter { $0.key != submission }
        next.designatedSpotter = designatedSpotter
        next.incidents = incidents
        self = next
        let receipt = author.map { [Outgoing(to: $0, .receipt(Receipt(id: f.id, status: .stored,
                                                                        detail: "\(core.player) is playing \(f.course.name) now" + (practiceOnly ? ", in practice." : "."))))] } ?? []
        let toObservers = core.observerPeers.map { Outgoing(to: $0, .course(f.course)) }
        return .changed(receipt + toObservers)
    }

    mutating func declineField(_ submission: UUID, core: CoreView) -> MissionStep {
        submissions.removeAll { $0.id == submission }
        let author = submitters.removeValue(forKey: submission).flatMap { core.peer(of: $0) }
        return MissionStep(author.map { [Outgoing(to: $0, .receipt(Receipt(id: submission, status: .refused,
                                                                            detail: "The leader passed on this field.")))] } ?? [])
    }

    // MARK: Internals

    private mutating func receiveSpot(_ r: SpotReport, from member: MemberID, core: CoreView, now: Date) -> MissionStep {
        guard let n = roundInFlight, let h = hole, r.round == n, r.hole == h.holeNumber,
              r.mission == h.mission?.number else { return .none }   // not the round in flight: ignored
        spotReports.removeAll { $0.member == member }
        spotReports.append(ReceivedSpot(report: r, member: member))
        if member == designatedSpotter, let lateral = r.lateral {
            return commit(Spot(call: r.call, lateral: lateral))
        }
        return MissionStep(statusOnly: true)
    }

    private mutating func fired(_ f: FiredReport, by member: MemberID?, core: CoreView, now: Date) -> MissionStep {
        if let member {
            let hasGunner = core.squad.members.contains { $0.role == .gunner }
            let isGunner = core.member(member)?.role == .gunner
            guard !hasGunner || isGunner else { return .none }
        }
        guard let h = hole, h.phase == .firing, !walkingOut, roundInFlight == nil, !h.atRoundLimit,
              let m = h.mission, f.hole == h.holeNumber, f.mission == m.number, f.round == h.roundsFired + 1 else { return .none }
        let held = core.holds.union(holds(core: core, now: now))
        if !held.isEmpty {
            incidents.append("Round \(f.round) on hole \(f.hole) reported fired under: " +
                             held.map(\.description).sorted().joined(separator: " "))
        }
        roundInFlight = f.round
        spotReports = []
        let ask = SpotRequest(hole: f.hole, mission: f.mission, round: f.round)
        return .changed(core.memberPeers.map { Outgoing(to: $0, .spotRequest(ask)) })
    }

    private mutating func revokeDownrange(player: String) {
        guard let n = hole?.holeNumber else { return }
        downrange.revoke(player: player, hole: n)
    }

    /// Applies one step to the hole; returns an error message instead of throwing.
    private mutating func apply(_ event: HoleEvent) -> String? {
        guard var h = hole else { return "No hole in play." }
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
        hole = h
        events.append(event)
        return nil
    }

    // MARK: Geometry

    /// Whether any part of a position's GPS accuracy circle lies in the fan: beyond the firing
    /// point, within the fan's radius and inside ± the fan's half-angle.
    public static func inFan(_ p: MemberPosition, _ fan: Fan) -> Bool {
        let limits = Safety.limits
        let d = Geo.distance(fan.origin, p.at)
        let acc = max(0, p.accuracy)
        if d <= max(firingPointRadius, acc) { return false }
        if d - acc > limits.fanRange { return false }
        let off = abs(((Geo.bearing(from: fan.origin, to: p.at) - fan.bearing).truncatingRemainder(dividingBy: 360) + 540)
            .truncatingRemainder(dividingBy: 360) - 180)
        let margin = Geo.degrees(asin(min(1, acc / d)))
        return off <= limits.fanHalfAngle + margin
    }

    /// The target a lock is for: the first leg's to begin, the next leg's to advance (the flag again
    /// on the flag leg), the current leg's to verify or observe.
    static func target(for purpose: LockPurpose, hole: Hole, play: HolePlay) -> HoleTarget {
        let t = hole.targets
        let i: Int
        switch purpose {
        case .initial: i = 0
        case .nextMission: i = play.onFlagLeg ? play.targetIndex : play.targetIndex + 1
        case .verify, .observation: i = play.targetIndex
        }
        return t[min(max(0, i), t.count - 1)]
    }

    /// The active fan while the squad could fire: from the firing position toward the current target.
    public func activeFan() -> Fan? {
        guard let h = hole, let info = currentHole, !walkingOut,
              h.phase == .setup || h.phase == .firing else { return nil }
        let origin = h.mission?.from ?? info.firingPoints[min(firingPoint, info.firingPoints.count - 1)]
        let aim = info.targets[min(h.targetIndex, info.targets.count - 1)].position
        return Fan(origin: origin, bearing: Geo.bearing(from: origin, to: aim))
    }
}

extension Result where Failure == SafetyBlock {
    var failureReasons: [SafetyReason] {
        if case let .failure(b) = self { return b.reasons }
        return []
    }
}

// MARK: - The squad core running golf

/// The commander's iPad playing golf: the squad core with `GolfMission`. Keeps the API the app
/// used before the split, so the app doesn't change.
public typealias SquadHost = SquadCore<GolfMission>

public extension SquadCore where M == GolfMission {
    static var positionTimeout: TimeInterval { GolfMission.positionTimeout }
    static var firingPointRadius: Double { GolfMission.firingPointRadius }
    static func inFan(_ p: MemberPosition, _ fan: Fan) -> Bool { GolfMission.inFan(p, fan) }
    internal static func target(for purpose: LockPurpose, hole: Hole, play: HolePlay) -> HoleTarget {
        GolfMission.target(for: purpose, hole: hole, play: play)
    }

    init(squad: Squad, course: Course, practice: Bool, joinCode: String) {
        self.init(squad: squad, mission: GolfMission(squad: squad, course: course, practice: practice), joinCode: joinCode)
    }

    /// Resumes from a saved round. Links and positions start empty; phones rejoin.
    init(round: SquadRound, joinCode: String) {
        self.init(squad: round.squad, mission: GolfMission(round: round), joinCode: joinCode, revision: round.revision)
    }

    /// The squad's round, as saved between launches.
    var round: SquadRound {
        var r = SquadRound(squad: squad, course: mission.course, practice: mission.practice)
        r.card = mission.card
        r.hole = mission.hole
        r.events = mission.events
        r.firingPoint = mission.firingPoint
        r.downrange = mission.downrange
        r.walkingOut = mission.walkingOut
        r.revision = revision
        return r
    }

    var locks: [ReceivedLock] { mission.locks }
    var spotReports: [ReceivedSpot] { mission.spotReports }
    var roundInFlight: Int? { mission.roundInFlight }
    var submissions: [FieldSubmission] { mission.submissions }
    var incidents: [String] { mission.incidents }
    var designatedSpotter: MemberID? {
        get { mission.designatedSpotter }
        set { mission.designatedSpotter = newValue }
    }

    func isDownrangeConfirmed() -> Bool { mission.isDownrangeConfirmed(player: player) }
    func activeFan() -> Fan? { mission.activeFan() }

    /// The only path from a solution to the commander's screen: SafetyKit's `clearSolution` first,
    /// then this squad's holds.
    func firingDisplay<S>(_ verdict: Result<Cleared<S>, SafetyBlock>, now: Date) -> FiringDisplay<S> {
        GroupGate.display(verdict, holds: holds(now: now))
    }

    /// Opens the next unfinished hole.
    mutating func startNextHole(firingPoint: Int = 0, now: Date) -> [Outgoing] {
        run(now) { m, core in m.startNextHole(firingPoint: firingPoint, core: core, now: now) }
    }
    /// The commander's own look downrange. No message can do this.
    mutating func confirmDownrange(now: Date) -> [Outgoing] { run(now) { m, core in m.confirmDownrange(core: core) } }
    /// Uses a member's lock for its purpose, after the flag check on this iPad's own course.
    mutating func useLock(_ id: UUID, now: Date) -> [Outgoing] { run(now) { m, core in m.useLock(id, core: core, now: now) } }
    /// Verifies with a taped distance, or none (nothing found: scored from the firing position).
    mutating func verify(closest: Double?, now: Date) -> [Outgoing] { run(now) { m, _ in m.verify(closest: closest) } }
    /// Cease fire: the squad walks out. Holds the squad until the hole moves on.
    mutating func ceaseFire(now: Date) -> [Outgoing] { run(now) { m, _ in m.ceaseFire() } }
    /// Back to the same firing position. Everyone was downrange, so the commander confirms again.
    mutating func resume(now: Date) -> [Outgoing] { run(now) { m, core in m.resume(core: core) } }
    mutating func finish(now: Date) -> [Outgoing] { run(now) { m, _ in m.finish() } }
    /// The commander calls Fired on the gunner's behalf.
    mutating func fired(now: Date) -> [Outgoing] { run(now) { m, core in m.firedByCommander(core: core, now: now) } }
    /// Commits a spot: the call from one member's report and the left/right from another's (or the same).
    mutating func commit(callFrom: MemberID, lateralFrom: MemberID?, now: Date) -> [Outgoing] {
        run(now) { m, _ in m.commit(callFrom: callFrom, lateralFrom: lateralFrom) }
    }
    mutating func commit(_ spot: Spot, now: Date) -> [Outgoing] { run(now) { m, _ in m.commit(spot) } }
    mutating func commitLost(now: Date) -> [Outgoing] { run(now) { m, _ in m.commitLost() } }
    /// Corrects round `number`'s spot (nil = lost) and replays the hole. Fire control's later
    /// corrections change with it.
    mutating func amend(round number: Int, to spot: Spot?, now: Date) -> [Outgoing] {
        run(now) { m, _ in m.amend(round: number, to: spot) }
    }
    /// Switches the squad to a field a member sent in. Only between holes: the squad keeps its
    /// members and starts a fresh card on the new field. Observers (the Theater) get the new course.
    mutating func adoptField(_ submission: UUID, now: Date) -> [Outgoing] {
        let squad = self.squad
        return run(now) { m, core in m.adoptField(submission, squad: squad, core: core) }
    }
    /// Drops a field a member sent in.
    mutating func declineField(_ submission: UUID, now: Date) -> [Outgoing] {
        run(now) { m, core in m.declineField(submission, core: core) }
    }
}
