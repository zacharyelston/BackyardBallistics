import Foundation
import CoreGeo
import SafetyKit
import RangingKit
import CourseKit
import RoundKit

public enum GroupError: Error, Equatable, Sendable {
    case noHole
    case wrongHole
    case notFiring
    case roundInFlight
    case noRoundInFlight
    case unknownReport
    case hole(HolePlayError)
    case blocked([SafetyReason])
}

/// The commander's iPad in v3 Squadz: the squad's game, owned in one place.
///
/// The squad is the player: one `HolePlay` per hole and one `Scorecard`. Members' phones send
/// positions, raw locks, spot proposals, "fired" and check fire; the host gates and commits them.
/// Nothing a member sends can confirm downrange, clear a range or show firing data. The host is
/// a value type with no I/O: every call returns the messages to send, so it runs the same under
/// `swift test`, over loopback, and in the app.
public struct SquadHost: Codable, Equatable, Sendable {
    public private(set) var squad: Squad
    public let course: Course
    public let practice: Bool
    /// The match host's device, or nil for a squad playing on its own.
    public let matchHost: DeviceID?
    public let device: DeviceID

    public private(set) var card: Scorecard
    public private(set) var hole: HolePlay?
    /// Every event of the current hole, for amending a spot by replay.
    public private(set) var events: [HoleEvent] = []
    /// Firing point index (`M` − 1) for the current hole.
    public private(set) var firingPoint = 0
    public private(set) var downrange = DownrangeLog()
    public private(set) var positions: [MemberID: MemberPosition] = [:]
    /// Devices that asked to join, waiting for the commander.
    public private(set) var pendingJoins: [DeviceID: JoinRequest] = [:]
    /// The round in flight, waiting for a committed spot.
    public private(set) var awaiting: SpotRequest?
    /// Members' spot reports for the round in flight, newest per member.
    public private(set) var reports: [MemberID: SpotReport] = [:]
    /// When set, this member's report (with a measured left/right) is committed as soon as it arrives.
    public var designatedSpotter: MemberID?
    /// Accept every join without asking. Off by default.
    public var autoApprove = false
    public private(set) var observations: [LockReport] = []

    public private(set) var match: MatchView?
    public private(set) var lastMatchContact: Date?
    /// Check fires raised here or by members that the match host hasn't confirmed seeing yet.
    public private(set) var localCheckFires: [CheckFire] = []
    /// Check fires whose downrange revocation has been applied.
    private var revoked: Set<UUID> = []
    public private(set) var revision = 0
    /// Refused or dropped input, newest last, for the commander's log.
    public private(set) var log: [String] = []

    public init(squad: Squad, course: Course, practice: Bool, matchHost: DeviceID?) {
        self.squad = squad
        self.course = course
        self.practice = practice
        self.matchHost = matchHost
        self.device = squad.commander
        self.card = Scorecard(course: course, player: squad.name, practice: practice, playerID: squad.id.raw)
    }

    public var currentHole: Hole? {
        guard let n = hole?.holeNumber else { return nil }
        return course.holes.first { $0.number == n }
    }

    /// Messages to register this squad with the match host. Send once after linking (and again after a relink).
    public func registration() -> [Outbound] {
        guard let matchHost else { return [] }
        return [Outbound(to: matchHost, .register(SquadEntry(squad: squad.id, name: squad.name, members: squad.members.map(\.id)))),
                Outbound(to: matchHost, .squadStatus(status))]
    }

    // MARK: Holds and firing data

    /// Everything holding this squad's firing data, apart from SafetyKit's own reasons.
    public func holds(now: Date) -> [Hold] {
        var h: [Hold] = []
        if matchHost != nil {
            if match?.current != squad.id { h.append(.notYourTurn) }
            if let last = lastMatchContact, now.timeIntervalSince(last) <= GroupRules.matchLeaseSeconds {} else { h.append(.matchHostLost) }
            h += match?.holds ?? []
        }
        for cf in localCheckFires where !h.contains(.checkFire(by: cf.by)) { h.append(.checkFire(by: cf.by)) }
        return h
    }

    /// The only way this squad's firing data reaches the screen: SafetyKit first, then the group's holds.
    /// Nil before the first mission of a hole.
    public func firingData<S>(_ solution: S, muzzleVelocity: Double, launcher: LauncherConformance,
                              roundID: String, now: Date) -> Gated<S>? {
        guard let play = hole, play.phase == .firing, let m = play.mission else { return nil }
        let safety = Safety.clearSolution(solution, distance: m.fireControl.aimRange, muzzleVelocity: muzzleVelocity,
                                          launcher: launcher, roundID: roundID, downrange: downrange,
                                          player: squad.name, hole: play.holeNumber)
        return GroupGate.gate(safety, holds: holds(now: now))
    }

    // MARK: Messages in

    public mutating func receive(_ message: GroupMessage, from sender: DeviceID, now: Date) -> [Outbound] {
        if let matchHost, sender == matchHost {
            guard case let .matchView(view) = message else { return note("Ignored \(kind(message)) from the match host") }
            return applyMatchView(view, now: now)
        }
        if let member = squad.member(on: sender) {
            guard message.isMemberMessage else { return note("Dropped \(kind(message)) from member \(member.name)") }
            return fromMember(member, message, now: now)
        }
        if case let .join(request) = message { return join(request, from: sender) }
        return note("Dropped \(kind(message)) from unknown device \(sender)")
    }

    private mutating func applyMatchView(_ view: MatchView, now: Date) -> [Outbound] {
        lastMatchContact = now
        guard view.revision >= (match?.revision ?? 0) else { return [] }
        match = view
        localCheckFires.removeAll { view.seenCheckFires.contains($0.id) }
        for cf in view.activeCheckFires { revokeFor(cf) }
        // Members' views only: echoing a status back would bounce between the two hosts forever.
        return changed(toMatch: false)
    }

    private mutating func fromMember(_ member: Member, _ message: GroupMessage, now: Date) -> [Outbound] {
        switch message {
        case .join:
            return [Outbound(to: member.device, .joined(member)), Outbound(to: member.device, .squadView(view(now: now)))]
        case var .position(p):
            p.member = member.id        // a phone reports only its own position
            positions[member.id] = p
            guard let matchHost else { return [] }
            return [Outbound(to: matchHost, .memberPositions(squad: squad.id, [p]))]
        case let .lock(report):
            return ack(report.id, to: member, result: lock(report))
        case let .fired(holeNumber, mission):
            return fired(hole: holeNumber, mission: mission, by: member, now: now)
        case let .spot(report):
            return spot(report, from: member, now: now)
        case let .checkFire(cf):
            return raiseCheckFire(CheckFire(id: cf.id, by: member.device), now: now)
        case .bye:
            positions[member.id] = nil
            return []
        default:
            return []
        }
    }

    private mutating func join(_ request: JoinRequest, from device: DeviceID) -> [Outbound] {
        guard request.courseID == course.id, request.courseVersion == course.version else {
            return [Outbound(to: device, .refused(reason: "This squad is playing \(course.name) version \(course.version)."))]
        }
        pendingJoins[device] = request
        return autoApprove ? approve(device) : []
    }

    /// The commander approves a phone that asked to join.
    public mutating func approve(_ device: DeviceID) -> [Outbound] {
        guard let request = pendingJoins.removeValue(forKey: device) else { return [] }
        let member = Member(id: request.member, name: request.name, device: device)
        squad.members.removeAll { $0.id == member.id || $0.device == device }
        squad.members.append(member)
        var out = [Outbound(to: device, .joined(member))]
        out += registration()
        return out + changed()
    }

    // MARK: Locks

    /// Recomputes a member's lock with this iPad's own course flag and runs `Safety.clearRange`.
    /// Returns the cleared range in metres and the lock's height difference.
    public func clearedRange(_ report: LockReport) -> Result<(range: Double, heightDifference: Double), GroupError> {
        guard let h = course.holes.first(where: { $0.number == report.hole }) else { return .failure(.wrongHole) }
        let lock = report.lock
        // The phone's pole height is not trusted: rebuild the reticle with the course's flag.
        let reticle = ReticleRange(focalPixels: lock.reticle.focalPixels, poleHeight: h.flag.poleHeightM,
                                   angleBelowLevel: lock.angleBelowLevel)
        guard let range = reticle.range(linePixels: lock.linePixels), range.isFinite else { return .failure(.blocked([])) }
        let b = Geo.radians(lock.bearing)
        switch Safety.clearRange(range, lie: lock.location, east: range * sin(b), north: range * cos(b), flag: h.flag.position) {
        case let .failure(block): return .failure(.blocked(block.reasons))
        case let .success(cleared):
            let hd = ReticleRange.heightDifference(range: cleared.value, cameraHeight: lock.cameraHeight,
                                                   angleBelowLevel: lock.angleBelowLevel)
            return .success((cleared.value, hd))
        }
    }

    private mutating func lock(_ report: LockReport) -> Result<Void, GroupError> {
        if report.purpose == .observation { observations.append(report); return .success(()) }
        guard let play = hole else { return .failure(.noHole) }
        guard report.hole == play.holeNumber else { return .failure(.wrongHole) }
        let cleared: (range: Double, heightDifference: Double)
        switch clearedRange(report) {
        case let .failure(e): return .failure(e)
        case let .success(c): cleared = c
        }
        let from = report.lock.location
        switch report.purpose {
        case .initial:
            if let fps = currentHole?.firingPoints, !fps.isEmpty {
                firingPoint = fps.indices.min { Geo.distance(fps[$0], from) < Geo.distance(fps[$1], from) } ?? 0
            }
            return apply(.begin(lockedRange: cleared.range, bearing: report.lock.bearing,
                                heightDifference: cleared.heightDifference, from: from))
        case .nextMission:
            return apply(.advance(lockedRange: cleared.range, bearing: report.lock.bearing,
                                  heightDifference: cleared.heightDifference, from: from))
        case .verify:
            guard play.phase == .ceased else { return .failure(.hole(.notCeased)) }
            return apply(.ceaseFire(closest: cleared.range))
        case .observation:
            return .success(())
        }
    }

    // MARK: Rounds and spots

    private mutating func fired(hole number: Int, mission: Int, by member: Member, now: Date) -> [Outbound] {
        guard let play = hole, play.holeNumber == number, play.phase == .firing, play.mission?.number == mission else {
            return note("\(member.name) called fired, but the squad isn't firing that mission")
        }
        guard awaiting == nil else { return note("\(member.name) called fired before the last round was spotted") }
        let request = SpotRequest(hole: number, mission: mission, round: play.roundsFired + 1)
        awaiting = request
        reports = [:]
        return squad.members.map { Outbound(to: $0.device, .spotRequest(request)) } + changed()
    }

    private mutating func spot(_ report: SpotReport, from member: Member, now: Date) -> [Outbound] {
        guard let a = awaiting, a.hole == report.hole, a.mission == report.mission, a.round == report.round else {
            return [Outbound(to: member.device, .ack(Ack(id: report.id, applied: false, reason: "That round isn't waiting for a spot.")))]
        }
        reports[member.id] = report
        var out = [Outbound(to: member.device, .ack(Ack(id: report.id, applied: true, reason: nil)))]
        if designatedSpotter == member.id, let lateral = report.lateral {
            out += (try? commit(call: report.call, lateral: lateral)) ?? []
        }
        return out
    }

    /// The commander commits the spot for the round in flight. Call and left/right may come from different reports.
    public mutating func commit(call: RangeCall, lateral: Double) throws -> [Outbound] {
        guard awaiting != nil else { throw GroupError.noRoundInFlight }
        try apply(.spot(Spot(call: call, lateral: lateral))).get()
        awaiting = nil
        reports = [:]
        return changed()
    }

    /// Commits the call from one member's report and the left/right from another's (or the same).
    public mutating func commit(callFrom: MemberID, lateralFrom: MemberID) throws -> [Outbound] {
        guard let c = reports[callFrom], let l = reports[lateralFrom]?.lateral else { throw GroupError.unknownReport }
        return try commit(call: c.call, lateral: l)
    }

    /// The round in flight was lost. It counts.
    public mutating func recordLost() throws -> [Outbound] {
        guard awaiting != nil else { throw GroupError.noRoundInFlight }
        try apply(.lost).get()
        awaiting = nil
        reports = [:]
        return changed()
    }

    /// Replaces the spot on an earlier round and replays the hole.
    public mutating func amend(round: Int, with spot: Spot) throws -> [Outbound] {
        guard let play = hole else { throw GroupError.noHole }
        var seen = 0
        var edited = events
        guard let i = edited.firstIndex(where: {
            switch $0 { case .spot, .lost: seen += 1; return seen == round; default: return false }
        }) else { throw GroupError.unknownReport }
        edited[i] = .spot(spot)
        do { hole = try play.replayed(edited) } catch let e as HolePlayError { throw GroupError.hole(e) }
        events = edited
        return changed()
    }

    // MARK: Commander actions

    /// Opens the next unfinished hole.
    public mutating func startNextHole() throws -> [Outbound] {
        guard hole == nil || hole?.phase == .finished else { throw GroupError.hole(.notCeased) }
        guard let n = card.nextHole, let h = course.holes.first(where: { $0.number == n }) else { throw GroupError.noHole }
        hole = HolePlay(hole: h)
        events = []
        firingPoint = 0
        awaiting = nil
        reports = [:]
        return changed()
    }

    /// The commander's own tap: the whole fan is clear. Only the commander can do this.
    public mutating func confirmDownrange() throws -> [Outbound] {
        guard let play = hole else { throw GroupError.noHole }
        downrange.confirm(player: squad.name, hole: play.holeNumber)
        return changed()
    }

    public mutating func ceaseFire() throws -> [Outbound] {
        guard awaiting == nil else { throw GroupError.roundInFlight }
        try apply(.ceaseFire(closest: nil)).get()
        return changed()
    }

    public mutating func resume() throws -> [Outbound] {
        try apply(.resume).get()
        return changed()
    }

    /// Finishes the hole at the verdict and writes it on the card.
    public mutating func finishHole() throws -> [Outbound] {
        try apply(.finish).get()
        if let play = hole { card.record(play) }
        return changed()
    }

    /// Check fire from the commander or a member: holds the squad at once, revokes this hole's
    /// downrange confirmation, and tells the match host.
    public mutating func raiseCheckFire(_ cf: CheckFire, now: Date) -> [Outbound] {
        if !localCheckFires.contains(cf) { localCheckFires.append(cf) }
        revokeFor(cf)
        var out: [Outbound] = []
        if let matchHost { out.append(Outbound(to: matchHost, .checkFireRaised(cf))) }
        return out + changed()
    }

    /// For a squad with no match host: the commander withdraws a check fire. Each commander still re-confirms downrange.
    public mutating func withdrawLocalCheckFire(_ id: UUID) -> [Outbound] {
        guard matchHost == nil else { return [] }
        localCheckFires.removeAll { $0.id == id }
        return changed()
    }

    // MARK: Views

    public var status: SquadStatus {
        SquadStatus(squad: squad.id, revision: revision, hole: hole?.holeNumber, phase: hole?.phase,
                    firingPoint: firingPoint, score: hole?.score)
    }

    public func view(now: Date) -> SquadView {
        let rounds = (hole?.rounds ?? []).map {
            RoundLine(number: $0.number, mission: $0.mission, call: $0.spot?.call, lateral: $0.spot?.lateral,
                      addDrop: $0.addDrop, rightLeft: $0.rightLeft, lost: $0.lost)
        }
        var scores: [Int: Double] = [:]
        for h in card.played { scores[h.number] = h.score }
        return SquadView(revision: revision, squad: squad.name, hole: hole?.holeNumber, phase: hole?.phase,
                         rounds: rounds, scores: scores, yourTurn: matchHost == nil || match?.current == squad.id,
                         holds: holds(now: now))
    }

    // MARK: Helpers

    private mutating func apply(_ event: HoleEvent) -> Result<Void, GroupError> {
        guard var play = hole else { return .failure(.noHole) }
        do { try play.apply(event) } catch let e as HolePlayError { return .failure(.hole(e)) } catch { return .failure(.noHole) }
        hole = play
        events.append(event)
        return .success(())
    }

    private mutating func revokeFor(_ cf: CheckFire) {
        guard !revoked.contains(cf.id) else { return }
        revoked.insert(cf.id)
        if let n = hole?.holeNumber { downrange.revoke(hole: n) }
    }

    private mutating func ack(_ id: UUID, to member: Member, result: Result<Void, GroupError>) -> [Outbound] {
        switch result {
        case .success:
            return [Outbound(to: member.device, .ack(Ack(id: id, applied: true, reason: nil)))] + changed()
        case let .failure(e):
            let reason: String
            if case let .blocked(r) = e, !r.isEmpty { reason = r.map(\.description).joined(separator: " ") } else { reason = "\(e)" }
            log.append("Refused a lock from \(member.name): \(reason)")
            return [Outbound(to: member.device, .ack(Ack(id: id, applied: false, reason: reason)))]
        }
    }

    /// Bumps the revision and sends the new view to members and the status to the match host.
    private mutating func changed(toMatch: Bool = true) -> [Outbound] {
        revision += 1
        let v = view(now: lastMatchContact ?? Date.distantPast)
        var out = squad.members.map { Outbound(to: $0.device, .squadView(v)) }
        if toMatch, let matchHost { out.append(Outbound(to: matchHost, .squadStatus(status))) }
        return out
    }

    private mutating func note(_ s: String) -> [Outbound] { log.append(s); return [] }

    private func kind(_ m: GroupMessage) -> String { String(describing: m).split(separator: "(").first.map(String.init) ?? "message" }
}
