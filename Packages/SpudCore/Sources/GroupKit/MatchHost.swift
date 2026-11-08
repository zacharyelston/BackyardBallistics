import Foundation
import CoreGeo
import CourseKit
import RoundKit

/// The match host in v3 Squadz (one commander's iPad): the match between squads, turn order,
/// the scoreboard, and the holds that cover the whole field. It never sees a squad's firing data;
/// it only grants turns and adds holds.
public struct MatchHost: Codable, Equatable, Sendable {
    public let course: Course
    public let device: DeviceID
    public private(set) var squads: [SquadID: SquadEntry] = [:]
    /// Commander device for each squad.
    public private(set) var commanders: [SquadID: DeviceID] = [:]
    public private(set) var statuses: [SquadID: SquadStatus] = [:]
    /// Turn order for the current hole.
    public private(set) var order: [SquadID] = []
    public private(set) var hole: Int?
    public private(set) var scores: [SquadID: [Int: Double]] = [:]
    public private(set) var activeCheckFires: [CheckFire] = []
    public private(set) var seenCheckFires: Set<UUID> = []
    public private(set) var positions: [MemberID: MemberPosition] = [:]
    /// Members the match host has accounted for on this turn (behind the line, gone home).
    public private(set) var excused: Set<MemberID> = []
    public private(set) var finished = false
    public private(set) var revision = 0

    public init(course: Course, device: DeviceID) {
        self.course = course
        self.device = device
    }

    /// The squad whose turn it is: the first in order without a score on this hole.
    public var current: SquadID? {
        guard let hole, !finished else { return nil }
        return order.first { scores[$0]?[hole] == nil }
    }

    // MARK: Messages in

    public mutating func receive(_ message: GroupMessage, from sender: DeviceID, now: Date) -> [Outbound] {
        switch message {
        case let .register(entry):
            if let existing = commanders[entry.squad], existing != sender { return [] }
            squads[entry.squad] = entry
            commanders[entry.squad] = sender
            if !order.contains(entry.squad) { order.append(entry.squad) }
            return changed(now: now)
        case let .squadStatus(s):
            guard commanders[s.squad] == sender, s.revision > (statuses[s.squad]?.revision ?? -1) else { return [] }
            let old = statuses[s.squad]
            statuses[s.squad] = s
            // Only the hole, phase, firing point and score matter here; skip a rebroadcast when none changed.
            if let old, old.hole == s.hole, old.phase == s.phase, old.firingPoint == s.firingPoint, old.score == s.score { return [] }
            if let n = s.hole, n == hole, s.phase == .finished, let score = s.score, scores[s.squad]?[n] == nil {
                scores[s.squad, default: [:]][n] = score
                excused = []
                if order.allSatisfy({ scores[$0]?[n] != nil }) { nextHole(after: n) }
            }
            return changed(now: now)
        case let .memberPositions(squad, list):
            guard commanders[squad] == sender, let roster = squads[squad]?.members else { return [] }
            for p in list where roster.contains(p.member) { positions[p.member] = p }
            return changed(now: now)
        case let .checkFireRaised(cf):
            guard commanders.values.contains(sender) else { return [] }
            seenCheckFires.insert(cf.id)
            if !activeCheckFires.contains(cf) { activeCheckFires.append(cf) }
            return changed(now: now)
        default:
            return []
        }
    }

    // MARK: Actions on the match host

    /// Starts the match at the first hole, squads in the order they registered.
    public mutating func start(now: Date) -> [Outbound] {
        hole = course.holes.map(\.number).min()
        return changed(now: now)
    }

    /// Check fire raised on the match host's own screen.
    public mutating func raiseCheckFire(now: Date) -> [Outbound] {
        let cf = CheckFire(by: device)
        seenCheckFires.insert(cf.id)
        activeCheckFires.append(cf)
        return changed(now: now)
    }

    /// Withdraws a check fire. Each commander must still confirm downrange again before firing.
    public mutating func withdrawCheckFire(_ id: UUID, now: Date) -> [Outbound] {
        activeCheckFires.removeAll { $0.id == id }
        return changed(now: now)
    }

    /// Accounts for a member whose position is unknown (behind the line, gone home) for this turn.
    public mutating func excuse(_ member: MemberID, now: Date) -> [Outbound] {
        excused.insert(member)
        return changed(now: now)
    }

    /// Re-sends the view to every commander. Run every few seconds as the lease heartbeat.
    public func heartbeat(now: Date) -> [Outbound] { broadcast(now: now) }

    // MARK: Holds

    /// Field-wide holds. `notYourTurn` is left to each commander.
    public func holds(now: Date) -> [Hold] {
        var h: [Hold] = []
        for id in order where statuses[id]?.phase == .ceased { h.append(.walkingOut(id)) }
        for cf in activeCheckFires { h.append(.checkFire(by: cf.by)) }
        guard let shooter = current, let n = hole, let courseHole = course.holes.first(where: { $0.number == n }) else { return h }
        let fpIndex = statuses[shooter]?.hole == n ? (statuses[shooter]?.firingPoint ?? 0) : 0
        guard courseHole.firingPoints.indices.contains(fpIndex) else { return h }
        let fp = courseHole.firingPoints[fpIndex]
        for id in order {
            for m in squads[id]?.members ?? [] where !excused.contains(m) {
                guard let p = positions[m], !p.isStale(now: now) else { h.append(.memberPositionUnknown(m)); continue }
                if FanCheck.mayBeInside(p.at, accuracy: p.accuracy, firingPoint: fp, flag: courseHole.flag.position) {
                    h.append(.memberInFan(m))
                }
            }
        }
        return h
    }

    public func view(now: Date) -> MatchView {
        MatchView(revision: revision, hole: hole, order: order, current: current, scores: scores, holds: holds(now: now),
                  activeCheckFires: activeCheckFires, seenCheckFires: seenCheckFires, finished: finished)
    }

    // MARK: Helpers

    private mutating func nextHole(after n: Int) {
        let numbers = course.holes.map(\.number).sorted()
        guard let next = numbers.first(where: { $0 > n }) else { finished = true; return }
        // The honour: lowest score on the hole just played goes first; ties keep the previous order.
        let previous = order
        order = previous.enumerated().sorted {
            let a = scores[$0.element]?[n] ?? .infinity, b = scores[$1.element]?[n] ?? .infinity
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        hole = next
    }

    private mutating func changed(now: Date) -> [Outbound] {
        revision += 1
        return broadcast(now: now)
    }

    private func broadcast(now: Date) -> [Outbound] {
        let v = view(now: now)
        return commanders.values.sorted { $0.raw.uuidString < $1.raw.uuidString }.map { Outbound(to: $0, .matchView(v)) }
    }
}
