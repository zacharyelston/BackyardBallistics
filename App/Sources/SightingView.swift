import SwiftUI
import RangingKit

/// Field test for milestone 1: photograph the pole from a taped distance, mark its tip and
/// base, and log how close the single-photo size range comes.
struct SightingView: View {
    @StateObject private var camera = CameraController()
    @State private var frame: FrozenFrame?

    var body: some View {
        Group {
            if let frame {
                MarkingView(frame: frame) { self.frame = nil }
            } else {
                live
            }
        }
        .navigationTitle("Sighting test")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var live: some View {
        VStack(spacing: 12) {
            ZStack {
                CameraPreview(session: camera.session)
                Rectangle().fill(.orange).frame(width: 1).opacity(0.6)
            }
            if !camera.status.isEmpty {
                Text(camera.status).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
            }
            Picker("Lens", selection: Binding(get: { camera.selected }, set: { if let l = $0 { camera.select(l) } })) {
                ForEach(camera.lenses) { Text($0.name).tag(Optional($0)) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            Text("Fit the whole pole in frame on the longest lens that holds it. Hold steady, then capture.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal)
            Button {
                frame = camera.freeze()
            } label: {
                Text("Capture").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.orange)
            .padding([.horizontal, .bottom])
        }
    }
}

struct MarkingView: View {
    let frame: FrozenFrame
    let retake: () -> Void

    @EnvironmentObject private var log: FieldLogStore
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @AppStorage(Settings.cameraHeightKey) private var cameraHeight = Settings.defaultCameraHeight
    @State private var tip: CGPoint?
    @State private var base: CGPoint?
    @State private var trueDistance: Double?
    @State private var note = ""
    @State private var logged = false

    private var sample: FieldSample? {
        guard let tip, let base else { return nil }
        let t = frame.bufferPoint(tip), b = frame.bufferPoint(base)
        return FieldSample(lens: frame.lens, approximateIntrinsics: frame.approximateIntrinsics, trueDistance: trueDistance,
                           poleHeight: poleHeight, cameraHeight: cameraHeight,
                           tip: (t.x, t.y), base: (b.x, b.y), intrinsics: frame.intrinsics, note: note)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                PoleMarker(frame: frame, tip: $tip, base: $base)
                results
            }
            .padding()
        }
        .onChange(of: tip) { _, _ in logged = false }
        .onChange(of: base) { _, _ in logged = false }
    }

    @ViewBuilder private var results: some View {
        if let s = sample {
            VStack(alignment: .leading, spacing: 8) {
                if let d = s.estimatedDistance {
                    Text("\(Units.metres(d))  ·  \(Units.yards(d))")
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    let sens = RangeMath.sensitivity(distance: d, poleHeight: poleHeight, cameraHeight: cameraHeight,
                                                     focalPixels: frame.intrinsics.fy)
                    Text(String(format: "Pole is %.0f px tall · 1 px error ≈ %@", s.polePixels, Units.metres(sens)))
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Those marks don't give a valid range. Check the tip and base.").foregroundStyle(.orange)
                }
                if frame.approximateIntrinsics {
                    Text("Lens calibration was estimated, so expect a few percent of extra error.")
                        .font(.footnote).foregroundStyle(.orange)
                }
                LabeledContent("Taped distance") {
                    HStack {
                        TextField("m", value: $trueDistance, format: .number.precision(.fractionLength(2)))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 90)
                        Text("m")
                    }
                }
                if let e = s.error, let pct = s.errorPercent {
                    Text(String(format: "Error %+.2f m (%+.1f%%)", e, pct)).monospacedDigit()
                        .foregroundStyle(abs(pct) < 2 ? .green : .orange)
                }
                TextField("Note (light, wind, grass at the base…)", text: $note)
                HStack {
                    Button("Retake", action: retake).buttonStyle(.bordered)
                    Spacer()
                    Button(logged ? "Logged" : "Log sample") {
                        log.add(s)
                        logged = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(logged)
                }
            }
        } else {
            Button("Retake", action: retake).buttonStyle(.bordered)
        }
    }
}
