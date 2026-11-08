import SwiftUI
import SafetyKit
import CourseKit

/// The round: start or continue one on the loaded course, as real fire missions or as practice
/// with simulated rounds, and look back at saved scorecards.
struct PlayView: View {
    @EnvironmentObject private var courses: CourseStore
    @EnvironmentObject private var rounds: RoundStore
    @EnvironmentObject private var squadCommand: SquadCommand
    @EnvironmentObject private var squadMembership: SquadMembership
    @AppStorage(Settings.playerNameKey) private var player = Settings.defaultPlayerName
    @State private var openRound = false
    @State private var confirmReplace: Bool?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let a = rounds.active {
                        NavigationLink {
                            RoundView()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(a.practice ? "Continue practice round" : "Continue round").font(.headline)
                                Text("\(a.course.name) · \(a.card.played.count) of \(a.card.holes.count) holes")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let course = courses.practiceCourse {
                        if courses.playableCourse != nil {
                            Button {
                                begin(course, practice: false)
                            } label: {
                                Label("Play \(course.name)", systemImage: "flag.fill")
                            }
                        } else {
                            Label {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(course.name) is practice only")
                                    Text("Its safety fan leaves the boundary, so real rounds are off. Practice and demos fire nothing.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                        Button {
                            begin(course, practice: true)
                        } label: {
                            Label("Practice with simulated rounds", systemImage: "gamecontroller")
                        }
                    } else {
                        Text("No playable course loaded.").foregroundStyle(.secondary)
                    }
                    LabeledContent("Player") {
                        TextField("Name", text: $player).multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Round")
                } footer: {
                    Text("Each hole is a fire mission: confirm downrange, range the pole, fire and spot, let fire control correct, cease fire and verify. Score is rounds plus metres outside the ring. Practice plays the same flow with simulated rounds and no launcher.")
                }
                Section {
                    NavigationLink { CommandSquadView() } label: {
                        Label(squadCommand.host.map { "Command \($0.player)" } ?? "Command a squad", systemImage: "ipad.landscape")
                    }
                    NavigationLink { JoinSquadView() } label: {
                        Label(squadMembership.squadName.map { squadMembership.state == .joined ? "In squad \($0)" : "Join squad" } ?? "Join squad",
                              systemImage: "person.3.fill")
                    }
                } header: {
                    Text("v3 Squadz")
                } footer: {
                    Text("Squads play squads. The commander's iPad hosts the squad; members join from their phones with its code.")
                }
                Section {
                    NavigationLink { CourseView() } label: { Label("Course", systemImage: "map") }
                    NavigationLink { ScorecardHistoryView(saved: rounds.saved) } label: {
                        Label("Scorecards", systemImage: "list.number")
                    }
                    NavigationLink { ReticleRangingView() } label: { Label("Range a pole now", systemImage: "scope") }
                }
            }
            .navigationTitle("Play")
            .navigationDestination(isPresented: $openRound) { RoundView() }
            .confirmationDialog("A round is in progress", isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } }),
                                titleVisibility: .visible) {
                Button("End it and start a new one", role: .destructive) {
                    if let practice = confirmReplace, let course = practice ? courses.practiceCourse : courses.playableCourse {
                        rounds.endRound()
                        rounds.start(course: course, player: player, practice: practice)
                        openRound = true
                    }
                }
            } message: {
                Text("Finished holes from the current round are saved to a scorecard.")
            }
        }
    }

    private func begin(_ course: Course, practice: Bool) {
        if rounds.active != nil { confirmReplace = practice; return }
        rounds.start(course: course, player: player, practice: practice)
        openRound = true
    }
}
