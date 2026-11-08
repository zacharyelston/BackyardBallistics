import SwiftUI
import CourseKit
import RoundKit

/// The round in progress: the scorecard so far and the way into the current hole.
struct RoundView: View {
    @EnvironmentObject private var rounds: RoundStore
    @Environment(\.dismiss) private var dismiss
    @State private var confirmEnd = false

    var body: some View {
        List {
            if let a = rounds.active {
                Section {
                    if let hole = a.currentHole, !a.card.isComplete {
                        NavigationLink {
                            HoleMissionView()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.hole == nil ? "Start hole \(hole.number)" : "Hole \(hole.number): \(phaseText(a.hole))")
                                    .font(.headline)
                                Text("\(hole.name) · par \(hole.par)").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text(String(format: "Round complete: %.1f against par %d. The card is saved.", a.card.total, a.card.totalPar))
                    }
                } header: {
                    Text(a.course.name + (a.practice ? " · Practice" : ""))
                }
                Section("Scorecard") { ScorecardTable(card: a.card, current: a.hole?.holeNumber) }
                Section {
                    Button(a.card.isComplete ? "Done" : "End round", role: a.card.isComplete ? nil : .destructive) {
                        if a.card.isComplete { rounds.endRound(); dismiss() } else { confirmEnd = true }
                    }
                }
            } else {
                ContentUnavailableView("No round in progress", systemImage: "flag")
            }
        }
        .navigationTitle(rounds.active?.practice == true ? "Practice round" : "Round")
        .confirmationDialog("End this round?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End and save the holes played", role: .destructive) { rounds.endRound(); dismiss() }
        } message: {
            Text("Finished holes are kept on a saved scorecard. The hole in play is dropped.")
        }
    }

    private func phaseText(_ h: HolePlay?) -> String {
        switch h?.phase {
        case .setup, nil: return "range the pole"
        case .firing: return "firing, \(h?.roundsFired ?? 0) rounds"
        case .ceased: return "ceased fire"
        case .finished: return "finished"
        }
    }
}

/// Hole-by-hole card: par, score and rounds, with the total against par for the holes played.
struct ScorecardTable: View {
    let card: Scorecard
    var current: Int? = nil

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                Text("Hole").gridColumnAlignment(.leading)
                Text("Par"); Text("Rounds"); Text("Closest"); Text("Score")
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(card.holes) { h in
                GridRow {
                    Text("\(h.number) \(h.name)").lineLimit(1).gridColumnAlignment(.leading)
                        .fontWeight(h.number == current ? .semibold : .regular)
                    Text("\(h.par)")
                    Text(h.rounds.map(String.init) ?? "–")
                    Text(h.closest.map { String(format: "%.1f m", $0) } ?? "–")
                    Text(h.score.map { String(format: "%.1f", $0) } ?? "–").fontWeight(.semibold)
                }
                .monospacedDigit()
            }
            Divider()
            GridRow {
                Text("Total").gridColumnAlignment(.leading)
                Text("\(card.totalPar)")
                Text(""); Text("")
                Text(String(format: "%.1f", card.total)).fontWeight(.bold)
            }
            .monospacedDigit()
        }
        .font(.footnote)
        if !card.played.isEmpty {
            Text(String(format: "%+.1f against par for %d hole%@", card.toPar, card.played.count, card.played.count == 1 ? "" : "s"))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Saved cards, newest first.
struct ScorecardHistoryView: View {
    @EnvironmentObject private var rounds: RoundStore
    @ObservedObject private var saved: JSONStore<Scorecard>

    init(saved: JSONStore<Scorecard>) { self.saved = saved }

    var body: some View {
        List {
            if saved.items.isEmpty {
                Text("No saved scorecards yet. A card is saved when a round ends.").foregroundStyle(.secondary)
            }
            ForEach(saved.items) { card in
                NavigationLink {
                    List { Section { ScorecardTable(card: card) } header: { Text(card.date.formatted(date: .abbreviated, time: .shortened)) } }
                        .navigationTitle(card.courseName)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(card.courseName + (card.practice ? " · Practice" : "")).font(.headline)
                        Text(String(format: "%@ · %.1f on %d hole%@ (par %d)", card.date.formatted(date: .abbreviated, time: .omitted),
                                    card.total, card.played.count, card.played.count == 1 ? "" : "s", card.parPlayed))
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            .onDelete { saved.delete(at: $0) }
        }
        .navigationTitle("Scorecards")
    }
}
