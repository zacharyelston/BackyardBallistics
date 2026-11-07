import SwiftUI
import SafetyKit

/// Your launcher's profile (from calibration shots, milestone 5) and the limits it must stay within.
struct LauncherView: View {
    private let limits = Safety.limits

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
