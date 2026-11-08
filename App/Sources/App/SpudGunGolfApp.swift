import SwiftUI

@main
struct SpudGunGolfApp: App {
    @StateObject private var fieldLog = FieldLogStore(fileName: "fieldlog.json")
    @StateObject private var rangingLog = RangingLogStore(fileName: "ranginglog.json")
    @StateObject private var reticleLog = ReticleLogStore(fileName: "reticlelog.json")
    @StateObject private var courseStore = CourseStore()
    @StateObject private var roundStore = RoundStore()
    @StateObject private var squadCommand = SquadCommand()
    @StateObject private var squadMembership = SquadMembership()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(fieldLog)
                .environmentObject(rangingLog)
                .environmentObject(reticleLog)
                .environmentObject(courseStore)
                .environmentObject(roundStore)
                .environmentObject(squadCommand)
                .environmentObject(squadMembership)
        }
    }
}

/// Three tabs, one per job: play a round, look after your launcher, and set up or test kit.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var squadCommand: SquadCommand
    @EnvironmentObject private var squadMembership: SquadMembership

    var body: some View {
        TabView {
            PlayView()
                .tabItem { Label("Play", systemImage: "flag.fill") }
            LauncherView()
                .tabItem { Label("Launcher", systemImage: "scope") }
            ToolsView()
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
        }
        .tint(.orange)
        // Back from sleep or the background: the squad's iPad reopens its listener at once, and a
        // member's phone retries without waiting out its backoff.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            squadCommand.sceneBecameActive()
            squadMembership.sceneBecameActive()
        }
    }
}
