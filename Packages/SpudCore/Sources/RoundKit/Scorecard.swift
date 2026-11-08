import Foundation
import CourseKit

/// One hole's line on the scorecard.
public struct HoleScore: Codable, Equatable, Sendable, Identifiable {
    public var number: Int
    public var name: String
    public var par: Int
    /// Nil until the hole is finished.
    public var score: Double?
    public var rounds: Int?
    /// Verified distance of the closest round, metres.
    public var closest: Double?
    public var missions: Int?

    public var id: Int { number }
}

/// A round of golf on one course: the card the app saves when the round ends (or is abandoned).
public struct Scorecard: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var date = Date()
    public var player: String
    /// Stable ID of the player (in v3 Squadz, the squad). Nil on solo cards and older files.
    public var playerID: UUID?
    public var courseID: String
    public var courseName: String
    public var courseVersion: Int
    /// Practice rounds use simulated rounds and are kept apart from real ones.
    public var practice: Bool
    public var holes: [HoleScore]

    public init(course: Course, player: String, practice: Bool, playerID: UUID? = nil) {
        self.player = player
        self.playerID = playerID
        self.courseID = course.id
        self.courseName = course.name
        self.courseVersion = course.version
        self.practice = practice
        self.holes = course.holes.map { HoleScore(number: $0.number, name: $0.name, par: $0.par) }
    }

    /// Writes a finished hole onto the card.
    public mutating func record(_ play: HolePlay) {
        guard let score = play.score, let i = holes.firstIndex(where: { $0.number == play.holeNumber }) else { return }
        holes[i].score = score
        holes[i].rounds = play.roundsFired
        holes[i].closest = play.verdict?.closest
        holes[i].missions = play.missions.count
    }

    public var played: [HoleScore] { holes.filter { $0.score != nil } }
    public var isComplete: Bool { holes.allSatisfy { $0.score != nil } }
    /// Sum of finished holes, to 0.1.
    public var total: Double { (played.reduce(0) { $0 + ($1.score ?? 0) } * 10).rounded() / 10 }
    public var parPlayed: Int { played.reduce(0) { $0 + $1.par } }
    public var totalPar: Int { holes.reduce(0) { $0 + $1.par } }
    /// Against par for the holes played (− is under).
    public var toPar: Double { ((total - Double(parPlayed)) * 10).rounded() / 10 }
    /// The first hole not yet finished.
    public var nextHole: Int? { holes.first { $0.score == nil }?.number }
}
