import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var log: FieldLogStore
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @AppStorage(Settings.cameraHeightKey) private var cameraHeight = Settings.defaultCameraHeight

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { LeanCheckView() } label: {
                        Label("Lean check", systemImage: "level")
                    }
                    NavigationLink { PoleHeightView() } label: {
                        Label("Measure pole height", systemImage: "ruler")
                    }
                } header: {
                    Text("Flag setup")
                } footer: {
                    Text("Guy the pole until the lean check reads under 0.5°, then measure its height.")
                }

                Section {
                    NavigationLink { SightingView() } label: {
                        Label("Sighting test", systemImage: "scope")
                    }
                    NavigationLink { FieldLogView() } label: {
                        Label("Field log", systemImage: "list.bullet.rectangle")
                            .badge(log.samples.count)
                    }
                } header: {
                    Text("Field test")
                } footer: {
                    Text("Photograph the pole from taped distances and log how close the range comes.")
                }

                Section("Ranging settings") {
                    LabeledContent("Pole height") {
                        HStack {
                            TextField("m", value: $poleHeight, format: .number.precision(.fractionLength(3)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 90)
                            Text("m")
                        }
                    }
                    Text(Units.feetInches(poleHeight)).foregroundStyle(.secondary).font(.footnote)
                    LabeledContent("Phone height when sighting") {
                        HStack {
                            TextField("m", value: $cameraHeight, format: .number.precision(.fractionLength(2)))
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 90)
                            Text("m")
                        }
                    }
                }
            }
            .navigationTitle("SpudGunGolf")
        }
    }
}
