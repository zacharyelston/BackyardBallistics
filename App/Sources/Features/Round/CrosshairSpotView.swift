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

    var body: some View { cameraContent.cameraNeedsPortrait() }

    @ViewBuilder private var cameraContent: some View {
        ZStack {
            Group {
                if let ar = session.source as? ARKitRangingSource {
                    ARViewContainer(arView: ar.arView)
                } else if let simImage {
                    Image(decorative: simImage, scale: 1).resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()
            ReticleOverlay(lineLength: 0, up: CGVector(dx: 0, dy: -1), locked: false)
                .allowsHitTesting(false).ignoresSafeArea()
            controls.environment(\.colorScheme, .dark)
        }
        .background(Color.black)
        .onAppear {
            if let sim = session.source as? SimulatedRangingSource { simImage = sim.preview(scale: 0.6) }
            session.start()
        }
        .onDisappear { session.pause() }
    }

    /// Mark buttons down the left, Use and Cancel at the top, the miss along the bottom; the middle
    /// stays clear for the crosshair.
    private var controls: some View {
        VStack(spacing: 10) {
            HStack {
                Button("Cancel") { dismiss() }
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                Spacer()
                Text("Measure left/right").font(.headline)
                Spacer()
                Button("Use") { if let miss { onMeasured(miss) }; dismiss() }
                    .fontWeight(.semibold)
                    .padding(.horizontal, 18).padding(.vertical, 8)
                    .background(miss == nil ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color.accentColor), in: Capsule())
                    .disabled(miss == nil)
            }
            .foregroundStyle(.white)
            Spacer()
            HStack {
                VStack(spacing: 10) {
                    HUDButton(title: poleBearing == nil ? "Mark pole" : "Re-mark pole", systemImage: "flag",
                              prominent: poleBearing == nil) { mark(&poleBearing) }
                        .disabled(!session.trackingReady)
                    HUDButton(title: roundBearing == nil ? "Mark round" : "Re-mark round", systemImage: "scope",
                              prominent: poleBearing != nil && roundBearing == nil) { mark(&roundBearing) }
                        .disabled(!session.trackingReady || poleBearing == nil)
                }
                Spacer()
            }
            Spacer()
            HUDPanel {
                VStack(alignment: .leading, spacing: 4) {
                    if let miss {
                        Text(abs(miss) < 0.05 ? "On line" : String(format: "%@ %.1f m", miss > 0 ? "Right" : "Left", abs(miss)))
                            .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    Text(problem ?? hint).font(.footnote).foregroundStyle(problem == nil ? Color.secondary : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var hint: String {
        if !session.trackingReady { return "Waiting for the camera to track…" }
        if poleBearing == nil { return "Crosshair on the pole's base, then Mark pole." }
        if roundBearing == nil { return "Crosshair on the round, then Mark round." }
        return String(format: "At %@ one degree is %.1f m. Re-mark either, or Use.",
                      Units.metres(range), Spotting.lateralMiss(crosshairAngleDegrees: 1, range: range))
    }

    private func mark(_ target: inout Double?) {
        guard let aim = session.source.liveAim() else { problem = "No heading yet. Hold steady and mark again."; return }
        target = aim.bearing
        problem = nil
    }
}
