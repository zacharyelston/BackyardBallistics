import Foundation
import CoreGeo
import RangingKit
import CourseKit

/// Hole rules that are about the game, not safety.
public enum HoleRules {
    /// The tenth round on a hole forces a cease fire.
    public static let maxRoundsPerHole = 10
    /// On a downrange hole, suggest the next mission (rather than finishing) when the closest round
    /// is at least this far outside the ring.
    public static let preferAdvanceGain = 3.0

    /// Rounds fired on the hole plus metres outside the ring for the closest round, to 0.1.
    public static func score(rounds: Int, closest: Double, inRadius: Double) -> Double {
        ((Double(rounds) + max(0, closest - inRadius)) * 10).rounded() / 10
    }
}

/// One fire mission: a lock from one firing position and fire control's bracketing from there.
public struct Mission: Codable, Equatable, Sendable, Identifiable {
    /// 1 for the course's firing point; 2, 3… for downrange missions from the closest round.
    public var number: Int
    /// Where the player fired from (GPS), when known.
    public var from: GeoPoint?
    /// Compass bearing of the line to the pole, degrees.
    public var bearing: Double
    /// Height of the pole's base relative to the firing position, metres (+ uphill).
    public var heightDifference: Double
    public var fireControl: FireControl

    public var id: Int { number }

    public init(number: Int, from: GeoPoint?, lockedRange: Double, bearing: Double, heightDifference: Double = 0) {
        self.number = number
        self.from = from
        self.bearing = bearing
        self.heightDifference = heightDifference
        self.fireControl = FireControl(lockedRange: lockedRange)
    }

    public var lockedRange: Double { fireControl.lockedRange }

    /// Unit vectors along the line to the pole and to its right, east/north.
    public var lineAxes: (along: (east: Double, north: Double), right: (east: Double, north: Double)) {
        let b = Geo.radians(bearing)
        return ((sin(b), cos(b)), (cos(b), -sin(b)))
    }

    /// Where fire control aims the next round, metres east and north of the firing position.
    public var aimPoint: (east: Double, north: Double) {
        let (u, n) = lineAxes
        let a = fireControl.aimRange, l = fireControl.lateralCorrection
        return (u.east * a + n.east * l, u.north * a + n.north * l)
    }
}

/// A round fired on a hole.
public struct FiredRound: Codable, Equatable, Sendable, Identifiable {
    /// Number on the hole, from 1.
    public var number: Int
    public var mission: Int
    /// The spot, or nil when the round was lost (water, out of bounds, not found).
    public var spot: Spot?
    /// Fire control's change for the next round after this one.
    public var addDrop: Double?
    public var rightLeft: Double?

    public var id: Int { number }
    public var lost: Bool { spot == nil }
}

/// The result of walking out after a cease fire.
public struct HoleVerdict: Codable, Equatable, Sendable {
    /// Verified distance from the closest round to the pole, metres.
    public var closest: Double
    public var inRing: Bool
    /// Score if the hole finishes here.
    public var score: Double
    /// The hole allows downrange play and the next mission may be fired from the closest round.
    public var canAdvance: Bool
    /// Advancing is the better move (closest round well outside the ring).
    public var preferAdvance: Bool
    /// Resume firing from the same position is allowed (not after the forced cease fire).
    public var canResume: Bool
    /// Metres outside the ring that count toward the score.
    public var outsideRing: Double
}

public enum HolePlayError: Error, Equatable, Sendable {
    case notFiring
    case noMission
    case roundLimit
    case notCeased
    case cannotAdvance
    case cannotResume
    case alreadyFinished
}

/// One hole, played as fire missions: fire and spot, cease fire, walk out and verify, then finish,
/// resume, or (on downrange holes) fire the next mission from the closest round.
public struct HolePlay: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        /// No mission yet: confirm downrange and range the pole.
        case setup
        case firing
        /// Ceased fire, walking out to verify.
        case ceased
        case finished
    }

    public let holeNumber: Int
    public let par: Int
    public let inRadius: Double
    public let downrangePlay: Bool
    public private(set) var phase: Phase = .setup
    public private(set) var missions: [Mission] = []
    public private(set) var rounds: [FiredRound] = []
    public private(set) var verdict: HoleVerdict?
    /// Final score once finished.
    public private(set) var score: Double?

    public init(holeNumber: Int, par: Int, inRadius: Double, downrangePlay: Bool) {
        self.holeNumber = holeNumber
        self.par = par
        self.inRadius = inRadius
        self.downrangePlay = downrangePlay
    }

    public init(hole: Hole) {
        self.init(holeNumber: hole.number, par: hole.par, inRadius: hole.flag.inRadiusM, downrangePlay: hole.downrangePlay)
    }

    public var mission: Mission? { missions.last }
    public var roundsFired: Int { rounds.count }
    public var roundsLeft: Int { HoleRules.maxRoundsPerHole - roundsFired }
    public var atRoundLimit: Bool { roundsFired >= HoleRules.maxRoundsPerHole }
    /// Rounds fired in the current mission.
    public var missionRounds: [FiredRound] { rounds.filter { $0.mission == mission?.number } }

    /// Starts the first mission from a lock at the firing point.
    public mutating func begin(lockedRange: Double, bearing: Double, heightDifference: Double = 0, from: GeoPoint?) throws {
        guard phase == .setup else { throw HolePlayError.notFiring }
        missions = [Mission(number: 1, from: from, lockedRange: lockedRange, bearing: bearing, heightDifference: heightDifference)]
        phase = .firing
    }

    /// Records a spotted round and returns fire control's correction for the next.
    @discardableResult
    public mutating func record(_ spot: Spot) throws -> FireControl.Correction {
        guard phase == .firing else { throw HolePlayError.notFiring }
        guard var m = missions.popLast() else { throw HolePlayError.noMission }
        guard !atRoundLimit else { missions.append(m); throw HolePlayError.roundLimit }
        let c = m.fireControl.record(spot)
        missions.append(m)
        rounds.append(FiredRound(number: rounds.count + 1, mission: m.number, spot: spot, addDrop: c.addDrop, rightLeft: c.rightLeft))
        return c
    }

    /// Records a round that was lost. It counts, and fire control is left alone.
    public mutating func recordLost() throws {
        guard phase == .firing else { throw HolePlayError.notFiring }
        guard let m = mission else { throw HolePlayError.noMission }
        guard !atRoundLimit else { throw HolePlayError.roundLimit }
        rounds.append(FiredRound(number: rounds.count + 1, mission: m.number, spot: nil))
    }

    /// Ceases fire. Everyone walks out together; `closest` is the verified distance from the
    /// closest round to the pole (ranged from that round, or taped). Nil when no round was found.
    @discardableResult
    public mutating func ceaseFire(closest: Double?) throws -> HoleVerdict {
        guard phase == .firing || phase == .ceased else { throw HolePlayError.notFiring }
        guard let m = mission else { throw HolePlayError.noMission }
        let found = rounds.contains { !$0.lost }
        // With nothing found, the hole is scored from where the player fired.
        let d = closest ?? m.lockedRange
        let inRing = d <= inRadius
        let canAdvance = downrangePlay && !inRing && found && closest != nil && !atRoundLimit
        let v = HoleVerdict(closest: d, inRing: inRing,
                            score: HoleRules.score(rounds: roundsFired, closest: d, inRadius: inRadius),
                            canAdvance: canAdvance,
                            preferAdvance: canAdvance && d - inRadius >= HoleRules.preferAdvanceGain,
                            canResume: !atRoundLimit && !inRing,
                            outsideRing: max(0, d - inRadius))
        verdict = v
        phase = .ceased
        return v
    }

    /// Back to the same firing position: same mission, same rounds.
    public mutating func resume() throws {
        guard phase == .ceased else { throw HolePlayError.notCeased }
        guard verdict?.canResume == true else { throw HolePlayError.cannotResume }
        verdict = nil
        phase = .firing
    }

    /// Downrange play: the next mission, fired from the closest round after ranging the pole from there.
    public mutating func advance(lockedRange: Double, bearing: Double, heightDifference: Double = 0, from: GeoPoint?) throws {
        guard phase == .ceased else { throw HolePlayError.notCeased }
        guard verdict?.canAdvance == true else { throw HolePlayError.cannotAdvance }
        missions.append(Mission(number: missions.count + 1, from: from, lockedRange: lockedRange,
                                bearing: bearing, heightDifference: heightDifference))
        verdict = nil
        phase = .firing
    }

    /// Finishes the hole at the verdict's score.
    @discardableResult
    public mutating func finish() throws -> Double {
        guard phase != .finished else { throw HolePlayError.alreadyFinished }
        guard phase == .ceased, let v = verdict else { throw HolePlayError.notCeased }
        score = v.score
        phase = .finished
        return v.score
    }
}
