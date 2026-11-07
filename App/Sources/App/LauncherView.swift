import SwiftUI
import SafetyKit

/// Your launcher's profile (from calibration shots, milestone 5) and the limits it must stay within.
struct LauncherView: View {
    private let limits = Safety.limits
    @State private var kind: LauncherKind = .pneumaticStandard

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("No launcher profile yet. Calibration shots will measure what each of your charge settings does, and the firing computer will use those numbers.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Profile")
                } footer: {
                    Text("Calibration shots arrive in milestone 5.")
                }

                Section {
                    Picker("Launcher type", selection: $kind) {
                        Text(LauncherKind.pneumaticStandard.title).tag(LauncherKind.pneumaticStandard)
                        Text(LauncherKind.elastic.title).tag(LauncherKind.elastic)
                    }
                    .pickerStyle(.segmented)
                    ForEach(Array(ConformanceStep.required(for: kind).enumerated()), id: \.element) { i, step in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(i + 1). \(step.title)").font(.subheadline.weight(.semibold))
                            Text(step.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    DisclosureGroup("Pre-round inspection items") {
                        ForEach(InspectionItem.items(for: kind), id: \.self) { item in
                            Label(item.prompt, systemImage: "checkmark.square").font(.footnote)
                        }
                    }
                } header: {
                    Text("Conformance")
                } footer: {
                    Text("No firing solutions until every step passes. Changing any pressure part starts conformance over. Combustion and home-built pressure parts never conform.")
                }

                Section {
                    LabeledContent("Muzzle velocity cap", value: String(format: "%.0f m/s", limits.maxMuzzleVelocity))
                    LabeledContent("Longest solution", value: String(format: "%.0f yd", limits.maxSolutionRange / 0.9144))
                    LabeledContent("Projectile", value: String(format: "%@, %.0f g", limits.projectile.name, limits.projectile.massKg * 1000))
                    LabeledContent("Range must land within", value: String(format: "%.0f m of a course flag", limits.flagGateTolerance))
                    LabeledContent("Safety fan", value: String(format: "%.0f yd, ±%.0f°", limits.fanRange / 0.9144, limits.fanHalfAngle))
                } header: {
                    Text("Safety limits")
                } footer: {
                    Text("These are fixed in the app (limits version \(limits.version)). A charge setting that calibrates over the cap is blocked, and the app never covers building, fuelling or tuning a launcher.")
                }
            }
            .navigationTitle("Launcher")
        }
    }
}
