import SwiftUI
import RangingKit

/// Left/right from the firing point: put the crosshair on the pole, then on the round. The angle
/// between them times the locked range is the miss across the line (+ right of the pole).
///
/// Uses the AR session's tracked heading, which is steady over the few seconds between the two marks
/// even when the compass's absolute north is a few degrees off.
struct CrosshairSpotView: View {
    let range: Double
    let onMeasured: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = RangingSession.make()
    @State private var poleBearing: Double?
    @State private var roundBearing: Double?
    @State private var simImage: CGImage?
    @State private var problem: String?

    private var miss: Double? {
        guard let p = poleBearing, let r = roundBearing else { return nil }
        let a = ((r - p).truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
        return Spotting.lateralMiss(crosshairAngleDegrees: a, range: range)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    if let ar = session.source as? ARKitRangingSource {
                        ARViewContainer(arView: ar.arView)
                    } else if let simImage {
                        Image(decorative: simImage, scale: 1).resizable().scaledToFill()
                    } else {
                        Color.black
                    }
                    ReticleOverlay(lineLength: 0, up: CGVector(dx: 0, dy: -1), locked: false).allowsHitTesting(false)
                }
                .frame(height: 360).clipped()
                List {
                    Section {
                        Button(poleBearing == nil ? "Mark the pole" : "Pole marked · mark again") { mark(&poleBearing) }
                            .disabled(!session.trackingReady)
                        Button(roundBearing == nil ? "Mark the round" : "Round marked · mark again") { mark(&roundBearing) }
                            .disabled(!session.trackingReady || poleBearing == nil)
                        if let miss {
                            Text(abs(miss) < 0.05 ? "On line" : String(format: "%@ %.1f m", miss > 0 ? "Right" : "Left", abs(miss)))
                                .font(.title2.weight(.bold)).monospacedDigit()
                        }
                        if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                    } footer: {
                        Text(String(format: "Crosshair on the pole's base, mark; then on the round, mark. At %@ one degree is %.1f m.",
                                    Units.metres(range), Spotting.lateralMiss(crosshairAngleDegrees: 1, range: range)))
                    }
                }
            }
            .navigationTitle("Measure left/right")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") { if let miss { onMeasured(miss) }; dismiss() }.disabled(miss == nil)
                }
            }
            .onAppear {
                if let sim = session.source as? SimulatedRangingSource { simImage = sim.preview(scale: 0.6) }
                session.start()
            }
            .onDisappear { session.pause() }
        }
    }

    private func mark(_ target: inout Double?) {
        guard let aim = session.source.liveAim() else { problem = "No heading yet. Hold steady and mark again."; return }
        target = aim.bearing
        problem = nil
    }
}
