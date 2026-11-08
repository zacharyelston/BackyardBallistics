import Foundation
import CoreGeo
import SafetyKit
import CourseKit
import RoundKit
import BallisticsKit

/// The round being played and the saved scorecards.
///
/// The round in progress (card, current hole, downrange confirmations) is written to Documents after
/// every change, so a phone that locks or an app that's closed mid-hole picks up where it was.
@MainActor
final class RoundStore: ObservableObject {
    struct Active: Codable, Equatable {
        var card: Scorecard
        var course: Course
        var hole: HolePlay?
        /// Firing point index (`M` − 1) chosen for the current hole.
        var firingPoint = 0
        var downrange = DownrangeLog()
        /// Practice only: where each round stopped, metres east/north of the hole's firing point, in round order.
        var practiceRests: [Ground] = []
        /// Practice only: each mission's firing position in the same frame, in mission order.
        var practiceOrigins: [Ground] = []
        /// Practice only: a round that has landed and waits for the player's call (and its measured left/right).
        var practicePending: Ground?
        var practicePendingLateral: Double?
        var seed: UInt64

        var practice: Bool { card.practice }
        var currentHole: Hole? {
            guard let n = hole?.holeNumber ?? card.nextHole else { return nil }
            return course.holes.first { $0.number == n }
        }
    }

    @Published var active: Active? { didSet { saveActive() } }
    let saved = JSONStore<Scorecard>(fileName: "scorecards.json")

    private let activeURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("round-in-progress.json")

    init() {
        if let data = try? Data(contentsOf: activeURL), let a = try? JSONDecoder().decode(Active.self, from: data) {
            active = a
        }
    }

    func start(course: Course, player: String, practice: Bool) {
        active = Active(card: Scorecard(course: course, player: player, practice: practice), course: course,
                        seed: UInt64.random(in: 1...UInt64(UInt32.max)))
    }

    /// Opens the next unfinished hole (or keeps the one in play).
    func startNextHole() {
        guard var a = active, a.hole == nil || a.hole?.phase == .finished,
              let n = a.card.nextHole, let hole = a.course.holes.first(where: { $0.number == n }) else { return }
        a.hole = HolePlay(hole: hole)
        a.firingPoint = 0
        a.practiceRests = []
        a.practiceOrigins = []
        a.practicePending = nil
        active = a
    }

    func update(_ change: (inout Active) -> Void) {
        guard var a = active else { return }
        change(&a)
        active = a
    }

    /// Writes the finished hole onto the card; saves the card when the round is complete.
    func recordFinishedHole() {
        guard var a = active, let h = a.hole, h.phase == .finished else { return }
        a.card.record(h)
        active = a
        if a.card.isComplete { saveCard() }
    }

    /// Saves the card as it stands and ends the round.
    func endRound() {
        if let a = active, !a.card.played.isEmpty { saveCard() }
        active = nil
    }

    private func saveCard() {
        guard let a = active, !saved.items.contains(where: { $0.id == a.card.id }) else { return }
        saved.add(a.card)
    }

    private func saveActive() {
        if let active, let data = try? JSONEncoder().encode(active) {
            try? data.write(to: activeURL, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: activeURL)
        }
    }
}

/// No launcher profile exists until calibration shots (milestone 5), so real fire missions are held
/// at initial data with SafetyKit's reasons. Practice needs no launcher.
enum LauncherProfile {
    static var current: LauncherConformance {
        LauncherConformance(launcherID: "none", name: "No launcher profile", kind: .pneumaticStandard)
    }
}
