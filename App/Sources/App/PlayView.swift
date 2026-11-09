import SwiftUI
import CourseKit

/// Play follows the active job. Setup and history stay reachable without interrupting a mission.
struct PlayView: View {
    @EnvironmentObject private var courses: CourseStore
    @EnvironmentObject private var rounds: RoundStore
    @EnvironmentObject private var squadCommand: SquadCommand
    @EnvironmentObject private var squadMembership: SquadMembership
    @AppStorage(Settings.playerNameKey) private var player = Settings.defaultPlayerName

    var body: some View {
        NavigationStack {
            if squadMembership.isInSquad {
                JoinSquadView()
            } else if squadCommand.host != nil {
                CommandSquadView()
            } else if let active = rounds.active {
                if active.card.isComplete {
                    RoundView()
                } else {
                    HoleMissionView()
                        .toolbar {
                            ToolbarItem(placement: .primaryAction) {
                                NavigationLink { RoundView() } label: { Label("Scorecard", systemImage: "list.number") }
                            }
                        }
                }
            } else {
                startScreen
            }
        }
        // Starting or leaving a session discards setup destinations from the old workspace.
        .id(workspace)
    }

    private var workspace: String {
        if squadMembership.isInSquad { return "member" }
        if squadCommand.host != nil { return "command" }
        if rounds.active != nil { return "solo" }
        return "start"
    }

    private var startScreen: some View {
        List {
            Section {
                NavigationLink { JoinSquadView() } label: { Label("Join squad", systemImage: "person.3.fill") }
                NavigationLink { CommandSquadView() } label: { Label("Start a squad", systemImage: "ipad.landscape") }
            } header: { Text("Play together") } footer: {
                Text("An iPad commands the squad. Members join from their phones.")
            }
            Section {
                if let course = courses.practiceCourse {
                    Text(course.name).font(.headline)
                    if courses.playableCourse != nil {
                        Button { rounds.start(course: course, player: player, practice: false) } label: {
                            Label("Play solo", systemImage: "flag.fill")
                        }
                    } else {
                        Label("Practice only", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        NavigationLink { CourseView() } label: { Text("Review course restrictions") }
                    }
                    Button { rounds.start(course: course, player: player, practice: true) } label: {
                        Label("Practice with simulated rounds", systemImage: "gamecontroller")
                    }
                } else {
                    NavigationLink { CourseView() } label: { Label("Load a course to play", systemImage: "map") }
                }
                LabeledContent("Player") { TextField("Name", text: $player).multilineTextAlignment(.trailing) }
            } header: { Text("Play solo") } footer: {
                Text("Practice uses simulated rounds and no launcher. Score is rounds plus metres outside the ring.")
            }
            Section {
                NavigationLink { ScorecardHistoryView(saved: rounds.saved) } label: { Label("Scorecards", systemImage: "list.number") }
            }
        }
        .navigationTitle("Play")
    }
}
