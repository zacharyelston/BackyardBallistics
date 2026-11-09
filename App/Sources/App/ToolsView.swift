import SwiftUI

/// The course and the work done out on the field, separate from equipment and diagnostics.
struct FieldView: View {
    @EnvironmentObject private var courses: CourseStore
    @EnvironmentObject private var reticleLog: ReticleLogStore

    var body: some View {
        NavigationStack {
            List {
                Section("Course") {
                    NavigationLink { CourseView() } label: {
                        Label(courses.practiceCourse?.name ?? "Load a course", systemImage: "map")
                    }
                    if let course = courses.practiceCourse {
                        NavigationLink {
                            SiteMap(squads: [SiteMapSquad(id: course.id, course: course, members: [],
                                                         positions: [:], activeHole: nil, walkingOut: true)])
                                .navigationTitle(course.name).navigationBarTitleDisplayMode(.inline)
                        } label: { Label("Course map", systemImage: "map.fill") }
                    }
                    NavigationLink { CourseSurveyView() } label: { Label("Survey a course", systemImage: "mappin.and.ellipse") }
                }
                Section("Ranging") {
                    NavigationLink { ReticleRangingView() } label: { Label("Range the pole", systemImage: "scope") }
                    NavigationLink { ReticleLogView() } label: {
                        Label("Recent measurements", systemImage: "clock").badge(reticleLog.items.count)
                    }
                }
                Section("Field records") {
                    NavigationLink { FieldNoteView() } label: { Label("Send a field note", systemImage: "note.text.badge.plus") }
                    NavigationLink { TargetCaptureView() } label: { Label("Capture a target", systemImage: "viewfinder.rectangular") }
                }
                Section {
                    NavigationLink { LeanCheckView() } label: { Label("Check pole lean", systemImage: "level") }
                    NavigationLink { PoleHeightView() } label: { Label("Measure pole height", systemImage: "ruler") }
                } header: { Text("Pole setup") } footer: {
                    Text("Check lean, measure the pole, then survey its position on the course.")
                }
            }
            .navigationTitle("Field")
        }
    }
}

/// Equipment settings and optional field-test tools, away from the active mission.
struct KitView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Equipment") {
                    NavigationLink { LauncherView() } label: { Label("Launcher", systemImage: "scope") }
                    NavigationLink { RangingSettingsView() } label: { Label("Ranging settings", systemImage: "slider.horizontal.3") }
                }
                Section {
                    NavigationLink { RangingDiagnosticsView() } label: {
                        Label("Tests and cross-checks", systemImage: "wrench.and.screwdriver")
                    }
                } header: { Text("Advanced") } footer: {
                    Text("Optional checks and test logs for setting up and evaluating your kit.")
                }
            }
            .navigationTitle("Kit")
        }
    }
}

private struct RangingDiagnosticsView: View {
    @EnvironmentObject private var fieldLog: FieldLogStore
    @EnvironmentObject private var rangingLog: RangingLogStore
    @AppStorage(Settings.simulatedCaptureKey) private var simulatedCapture = false

    var body: some View {
        List {
            Section {
                NavigationLink { RangingView() } label: { Label("Multi-photo cross-check", systemImage: "camera.metering.multispot") }
                NavigationLink { RangingLogView() } label: { Label("Cross-check history", systemImage: "clock").badge(rangingLog.items.count) }
            } header: { Text("Independent cross-check") } footer: {
                Text("Use three to five marked photos of the pole from a short arc.")
            }
            Section("Sighting test") {
                NavigationLink { SightingView() } label: { Label("Run a sighting test", systemImage: "scope") }
                NavigationLink { FieldLogView() } label: { Label("Test history", systemImage: "clock").badge(fieldLog.items.count) }
            }
            Section {
                Toggle("Simulated camera for ranging", isOn: $simulatedCapture)
            } footer: { Text("Uses a simulated scene instead of the camera for ranging tools.") }
        }
        .navigationTitle("Tests and cross-checks").navigationBarTitleDisplayMode(.inline)
    }
}

private struct RangingSettingsView: View {
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @AppStorage(Settings.cameraHeightKey) private var cameraHeight = Settings.defaultCameraHeight

    var body: some View {
        Form {
            Section("Pole") {
                LabeledContent("Height") {
                    HStack {
                        TextField("m", value: $poleHeight, format: .number.precision(.fractionLength(3)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 90)
                        Text("m")
                    }
                }
                Text(Units.feetInches(poleHeight)).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Phone") {
                LabeledContent("Height when sighting") {
                    HStack {
                        TextField("m", value: $cameraHeight, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 90)
                        Text("m")
                    }
                }
            }
        }
        .navigationTitle("Ranging settings").navigationBarTitleDisplayMode(.inline)
    }
}
