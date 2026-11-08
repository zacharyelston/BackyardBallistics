import Foundation
import CoreGeo
import SafetyKit
import CourseKit

/// A member's last known position, as the match host tracks it.
public struct TrackedPosition: Equatable, Sendable {
    public var position: MemberPosition
    public var squad: SquadID
}

/// The match host (one of the commanders' iPads): squads, turn order between them, the scoreboard,
/// and the holds that span the whole field. It never sees a squad's firing data.
public struct MatchHost {
    public private(set) var state: MatchState
    public let joinCode: String
    public private(set) var commanders: [PeerID: SquadID] = [:]
    public private(set) var reports: [SquadID: SquadReport] = [:]
    public private(set) var positions: [MemberID: TrackedPosition] = [:]
    public private(set) var activeCheckFire: CheckFire?
    private let holeNumbers: [Int]

    /// A member's position older than this counts as unknown, which holds the match.
    public static let positionTimeout: TimeInterval = 15
    /// Within this of the fan's origin (or the GPS accuracy, if larger), a member is at the firing
    /// point, behind the fan, not in it.
    public static let firingPointRadius = 5.0

    public init(course: Course, joinCode: String) {
        self.joinCode = joinCode
        self.holeNumbers = course.holes.map(\.number).sorted()
        self.state = MatchState(revision: 0, courseID: course.id, courseVersion: course.version,
                                courseHash: CourseFingerprint.hash(course), squads: [], started: false, turn: nil,
                                scores: [:], holds: [], knownCheckFires: [])
    }

    // MARK: Messages

    public mutating func handle(_ message: GroupMessage, from peer: PeerID, now: Date) -> [Outgoing] {
        guard message.protocolVersion == GroupProtocol.version else {
            return [Outgoing(to: peer, .refused("Protocol version \(message.protocolVersion); the match host speaks \(GroupProtocol.version)."))]
        }
        if case let .joinMatch(j) = message.body { return join(j, peer: peer, now: now) }
        guard let squad = commanders[peer] else { return [] }   // only commanders talk to the match host

        switch message.body {
        case let .squadReport(r):
            guard r.squad == squad else { return [] }   // a commander reports only for its own squad
            reports[squad] = r
            state.scores[squad] = r.scores
            advanceTurn()
            return changed(now: now)
        case let .positions(s, list):
            guard s == squad else { return [] }
            let roster = Set(reports[squad]?.members.map(\.id) ?? [])
            for p in list {
                guard let m = p.member, roster.contains(m) else { continue }
                if let old = positions[m], old.position.time > p.time { continue }
                positions[m] = TrackedPosition(position: p, squad: squad)
            }
            return recompute(now: now) ? changed(now: now) : []
        case let .checkFire(cf):
            return raiseCheckFire(cf, now: now)
        default:
            return []
        }
    }

    private mutating func join(_ j: JoinMatch, peer: PeerID, now: Date) -> [Outgoing] {
        guard j.joinCode == joinCode else { return [Outgoing(to: peer, .refused("Wrong match code."))] }
        guard j.courseID == state.courseID, j.courseVersion == state.courseVersion, j.courseHash == state.courseHash else {
            return [Outgoing(to: peer, .refused("This match is on \(state.courseID) v\(state.courseVersion); load the same course file."))]
        }
        let known = state.squads.contains { $0.id == j.squad }
        guard known || !state.started else { return [Outgoing(to: peer, .refused("The match has started."))] }
        if !known { state.squads.append(SquadEntry(id: j.squad, name: j.name)) }
        commanders = commanders.filter { $0.value != j.squad }
        commanders[peer] = j.squad
        return changed(now: now)
    }

    // MARK: Match host's actions

    public mutating func start(now: Date) -> [Outgoing] {
        guard !state.started, let first = state.squads.first, let hole = holeNumbers.first else { return [] }
        state.started = true
        state.turn = Turn(hole: hole, squad: first.id)
        advanceTurn()
        return changed(now: now)
    }

    /// Check fire called on the match host's own iPad.
    public mutating func callCheckFire(by: String, now: Date) -> [Outgoing] {
        raiseCheckFire(CheckFire(by: by), now: now)
    }

    /// Lifts check fire. Each commander still has to confirm downrange again before firing data shows.
    public mutating func withdrawCheckFire(now: Date) -> [Outgoing] {
        guard activeCheckFire != nil else { return [] }
        activeCheckFire = nil
        return changed(now: now)
    }

    /// The heartbeat: recomputes the holds (positions go stale with time) and sends the state to
    /// every commander. Call about once a second.
    public mutating func tick(now: Date) -> [Outgoing] {
        if recompute(now: now) { state.revision += 1 }
        return broadcast()
    }

    // MARK: Turns

    /// Moves the turn on while the squad on turn has finished the hole.
    private mutating func advanceTurn() {
        while let t = state.turn, state.scores[t.squad]?[t.hole] != nil {
            if let next = state.squads.first(where: { state.scores[$0.id]?[t.hole] == nil }) {
                state.turn = Turn(hole: t.hole, squad: next.id)
            } else if let hole = holeNumbers.first(where: { $0 > t.hole }), let first = state.squads.first {
                state.turn = Turn(hole: hole, squad: first.id)
            } else {
                state.turn = nil
            }
        }
    }

    // MARK: Holds

    private mutating func raiseCheckFire(_ cf: CheckFire, now: Date) -> [Outgoing] {
        guard !state.knownCheckFires.contains(cf.id) else { return [] }
        state.knownCheckFires.append(cf.id)
        if activeCheckFire == nil { activeCheckFire = cf }
        return changed(now: now)
    }

    /// Recomputes the field-wide holds; true if they changed.
    @discardableResult
    private mutating func recompute(now: Date) -> Bool {
        var h: [Hold] = []
        if let cf = activeCheckFire { h.append(.checkFire(by: cf.by)) }
        for s in state.squads {
            if let r = reports[s.id], r.walkingOut || r.phase == .ceased { h.append(.walkingOut(s.id)) }
        }
        if state.started && !state.finished {
            let fan = state.turn.flatMap { reports[$0.squad]?.fan }
            for s in state.squads {
                for m in reports[s.id]?.members ?? [] {
                    guard let p = positions[m.id]?.position, now.timeIntervalSince(p.time) <= Self.positionTimeout else {
                        h.append(.positionUnknown(m.id, name: m.name))
                        continue
                    }
                    if let fan, Self.inFan(p, fan) { h.append(.memberInFan(m.id, name: m.name)) }
                }
            }
        }
        guard h != state.holds else { return false }
        state.holds = h
        return true
    }

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

    // MARK: Sending

    private mutating func changed(now: Date) -> [Outgoing] {
        recompute(now: now)
        state.revision += 1
        return broadcast()
    }

    private func broadcast() -> [Outgoing] {
        commanders.keys.sorted { $0.raw < $1.raw }.map { Outgoing(to: $0, .matchState(state)) }
    }
}
