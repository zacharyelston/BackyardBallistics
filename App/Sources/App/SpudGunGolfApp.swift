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
    @StateObject private var theaterLink = TheaterLink()

    var body: some Scene {
        WindowGroup {
            Group {
                #if DEBUG
                if let scene = DesignScene.current { DesignSceneView(scene: scene) } else { RootView() }
                #else
                RootView()
                #endif
            }
                .environmentObject(fieldLog)
                .environmentObject(rangingLog)
                .environmentObject(reticleLog)
                .environmentObject(courseStore)
                .environmentObject(roundStore)
                .environmentObject(squadCommand)
                .environmentObject(squadMembership)
                .environmentObject(theaterLink)
        }
    }
}

/// Stable destinations for the active game, the field, and equipment.
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var squadCommand: SquadCommand
    @EnvironmentObject private var squadMembership: SquadMembership

    enum Tab: Hashable { case play, field, kit }
    @State private var selection: Tab

    init(selectedTab: Tab = .play) { _selection = State(initialValue: selectedTab) }

    var body: some View {
        TabView(selection: $selection) {
            PlayView()
                .safeAreaInset(edge: .bottom, spacing: 0) { OrderBanner() }
                .tabItem { Label("Play", systemImage: "flag.fill") }.tag(Tab.play)
            FieldView()
                .safeAreaInset(edge: .bottom, spacing: 0) { OrderBanner() }
                .tabItem { Label("Field", systemImage: "map") }.tag(Tab.field)
            KitView()
                .safeAreaInset(edge: .bottom, spacing: 0) { OrderBanner() }
                .tabItem { Label("Kit", systemImage: "wrench.and.screwdriver") }.tag(Tab.kit)
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
