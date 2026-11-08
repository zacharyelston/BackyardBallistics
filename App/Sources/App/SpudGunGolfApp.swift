import SwiftUI

@main
struct SpudGunGolfApp: App {
    @StateObject private var fieldLog = FieldLogStore(fileName: "fieldlog.json")
    @StateObject private var rangingLog = RangingLogStore(fileName: "ranginglog.json")
    @StateObject private var reticleLog = ReticleLogStore(fileName: "reticlelog.json")
    @StateObject private var courseStore = CourseStore()
    @StateObject private var roundStore = RoundStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(fieldLog)
                .environmentObject(rangingLog)
                .environmentObject(reticleLog)
                .environmentObject(courseStore)
                .environmentObject(roundStore)
        }
    }
}

/// Three tabs, one per job: play a round, look after your launcher, and set up or test kit.
struct RootView: View {
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
    }
}
