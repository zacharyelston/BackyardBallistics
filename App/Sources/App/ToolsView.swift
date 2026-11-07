import SwiftUI

/// Setup, ranging and field-test tools. During a round the Play tab drives these same features.
struct ToolsView: View {
    @EnvironmentObject private var fieldLog: FieldLogStore
    @EnvironmentObject private var rangingLog: RangingLogStore
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @AppStorage(Settings.cameraHeightKey) private var cameraHeight = Settings.defaultCameraHeight
    @AppStorage(Settings.simulatedCaptureKey) private var simulatedCapture = false

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
                    NavigationLink { RangingView() } label: {
                        Label("Range the flag", systemImage: "camera.metering.multispot")
                    }
                    NavigationLink { RangingLogView() } label: {
                        Label("Ranging log", systemImage: "list.number")
                            .badge(rangingLog.items.count)
                    }
                } header: {
                    Text("Ranging")
                } footer: {
                    Text("Three to five photos of the pole from a short arc give distance, height difference and a cross-check.")
                }

                Section {
                    NavigationLink { SightingView() } label: {
                        Label("Sighting test", systemImage: "scope")
                    }
                    NavigationLink { FieldLogView() } label: {
                        Label("Field log", systemImage: "list.bullet.rectangle")
                            .badge(fieldLog.items.count)
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
                    Toggle("Simulated camera for ranging", isOn: $simulatedCapture)
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
            .navigationTitle("Tools")
        }
    }
}
