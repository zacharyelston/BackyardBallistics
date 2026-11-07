import SwiftUI

/// Setup, ranging and field-test tools. During a round the Play tab drives these same features.
struct ToolsView: View {
    @EnvironmentObject private var fieldLog: FieldLogStore
    @EnvironmentObject private var rangingLog: RangingLogStore
    @EnvironmentObject private var reticleLog: ReticleLogStore
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
                    NavigationLink { ReticleRangingView() } label: {
                        Label("Range the pole", systemImage: "scope")
                    }
                    NavigationLink { ReticleLogView() } label: {
                        Label("Reticle log", systemImage: "list.number")
                            .badge(reticleLog.items.count)
                    }
                } header: {
                    Text("Ranging")
                } footer: {
                    Text("Crosshair on the pole's base, turn the dial until the plumb line meets the pole's top, lock.")
                }

                Section {
                    NavigationLink { RangingView() } label: {
                        Label("Multi-photo cross-check", systemImage: "camera.metering.multispot")
                    }
                    NavigationLink { RangingLogView() } label: {
                        Label("Multi-photo log", systemImage: "list.bullet")
                            .badge(rangingLog.items.count)
                    }
                } header: {
                    Text("Cross-check (optional)")
                } footer: {
                    Text("Three to five marked photos of the pole from a short arc give an independent distance and height difference.")
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
