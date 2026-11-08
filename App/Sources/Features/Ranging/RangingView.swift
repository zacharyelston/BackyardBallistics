import SwiftUI
import RealityKit
import RangingKit
import CoreGeo
import SafetyKit

/// Optional cross-check for the reticle: range the pole's base from a few marked photos taken along a short arc.
struct RangingView: View {
    @StateObject private var session = RangingSession.make()
    @EnvironmentObject private var rangingLog: RangingLogStore
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @AppStorage(Settings.cameraHeightKey) private var cameraHeight = Settings.defaultCameraHeight
    @AppStorage(Settings.flagLatKey) private var flagLat = 0.0
    @AppStorage(Settings.flagLonKey) private var flagLon = 0.0

    @State private var pending: FrozenFrame?
    @State private var captureFailed = false
    @State private var trueDistance: Double?
    @State private var note = ""
    @State private var logged = false

    private let targetBaseline = 3.0

    private var flagPoint: GeoPoint? {
        flagLat == 0 && flagLon == 0 ? nil : GeoPoint(latitude: flagLat, longitude: flagLon)
    }

    private var report: RangeReport? {
        PoleSolver.report(session.sightings, poleHeight: poleHeight, cameraHeight: cameraHeight)
    }

    /// The safety gate: a range only counts if it lands near a course flag.
    private var gate: Safety.FlagCheck? {
        guard let r = report, let lie = session.lieLocation, flagPoint != nil else { return nil }
        let en = r.eastNorth
        return Safety.checkFlag(lie: lie, east: en.east, north: en.north, flag: flagPoint)
    }

    var body: some View { cameraContent.cameraNeedsPortrait() }

    @ViewBuilder private var cameraContent: some View {
        VStack(spacing: 0) {
            ZStack {
                CaptureFeedView(session: session)
                Rectangle().fill(.orange).frame(width: 1).opacity(0.6)
                VStack {
                    Text(session.source.isSimulated ? "Simulated · \(session.tracking.label)" : session.tracking.label)
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                }
                .padding(8)
            }
            .frame(height: 300)

            List {
                captureSection
                if let r = report { resultSection(r) }
                flagSection
                if report != nil { logSection }
            }
        }
        .navigationTitle("Multi-photo cross-check")
        .toolbar(.hidden, for: .tabBar)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pending) { frame in
            MarkPhotoSheet(frame: frame) { tip, base in
                if let pose = frame.pose {
                    session.add(PoleSighting(pose: pose, intrinsics: frame.intrinsics,
                                             tip: frame.bufferPixel(tip), base: frame.bufferPixel(base)))
                    logged = false
                }
                pending = nil
            } cancel: { pending = nil }
        }
        .onAppear { session.start() }
        .onDisappear { session.pause() }
    }

    private var captureSection: some View {
        Section {
            Button {
                if let f = session.capture() { pending = f; captureFailed = false } else { captureFailed = true }
            } label: {
                Label(session.sightings.isEmpty ? "Take photo 1 at your lie" : "Take photo \(session.sightings.count + 1)",
                      systemImage: "camera.viewfinder")
                    .font(.headline)
            }
            .disabled(!session.trackingReady)
            if captureFailed {
                Text("Couldn't take that photo. Wait for tracking, then try again.").font(.footnote).foregroundStyle(.orange)
            }
            if !session.sightings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: min(session.baseline / targetBaseline, 1))
                    Text(String(format: "Baseline %.1f of %.0f m. Step sideways, across the line to the flag, and take 2–4 more photos.",
                                session.baseline, targetBaseline))
                        .font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Array(session.sightings.enumerated()), id: \.element.id) { i, s in
                    photoRow(index: i, sighting: s)
                }
                .onDelete { session.sightings.remove(atOffsets: $0); logged = false }
                Button("Start over", role: .destructive) { session.reset(); logged = false }
            }
        } header: {
            Text("Photos")
        } footer: {
            Text("Photo 1 is your lie. Fit the whole pole in frame; the orange line helps you centre it.")
        }
    }

    private func photoRow(index i: Int, sighting s: PoleSighting) -> some View {
        let fix = PoleSolver.solve(session.sightings, poleHeight: poleHeight)
        let residual = fix?.residualDegrees[s.id]
        let dropped = fix?.dropped.contains(s.id) ?? false
        let size = report?.sizeRanges[s.id]
        return HStack {
            Text("Photo \(i + 1)").font(.subheadline.weight(.semibold))
            if i == 0 { Text("lie").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if let size { Text(Units.metres(size)).font(.footnote).monospacedDigit().foregroundStyle(.secondary) }
            if dropped {
                Text("dropped").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            } else if let residual {
                Text(String(format: "%.3f°", residual)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func resultSection(_ r: RangeReport) -> some View {
        Section("Result") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Units.metres(r.distance))  ·  \(Units.yards(r.distance))")
                    .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                Text(String(format: "± %@ (1σ) · %d photo%@%@", Units.metres(r.distanceSigma), r.photoCount,
                            r.photoCount == 1 ? "" : "s", r.droppedCount > 0 ? ", 1 dropped" : ""))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Height difference", value: String(format: "%+.2f m %@", r.heightDifference,
                                                               r.heightDifference >= 0 ? "(uphill)" : "(downhill)"))
            LabeledContent("Baseline", value: String(format: "%.1f m", r.baseline))
            HStack {
                Text("Photo agreement")
                Spacer()
                Text(String(format: "%.1f%%", r.maxDisagreementPercent)).monospacedDigit()
                Text(r.confident ? "Good" : "Check marks")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(r.confident ? Color.green.opacity(0.2) : Color.orange.opacity(0.25), in: Capsule())
            }
            if r.photoCount == 1 {
                Text("One photo gives a size range only. Add photos from a few steps across for triangulation and a cross-check.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var flagSection: some View {
        Section {
            if let g = gate, let miss = g.miss {
                HStack {
                    Text(String(format: "Ranged hole is %.1f m from the flag point", miss))
                    Spacer()
                    Image(systemName: g.verdict.isAllowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                        .foregroundStyle(g.verdict.isAllowed ? .green : .red)
                }
                ForEach(Array(g.verdict.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(reason.description).font(.footnote).foregroundStyle(.red)
                }
            } else if flagPoint == nil {
                Text("No flag point saved. Stand at the pole and save one to test the flag check.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if session.lieLocation == nil {
                Text("Waiting for GPS at the lie.").font(.footnote).foregroundStyle(.secondary)
            }
            Button("Save my GPS position as the flag point") {
                if let c = session.currentLocation {
                    flagLat = c.latitude
                    flagLon = c.longitude
                }
            }
            .disabled(session.currentLocation == nil)
            if let sim = session.source as? SimulatedRangingSource {
                Button("Use the simulated scene's flag point") {
                    flagLat = sim.flagPoint.latitude
                    flagLon = sim.flagPoint.longitude
                }
            }
            if let a = session.horizontalAccuracy {
                Text(String(format: "GPS accuracy now ±%.0f m", a))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Flag check")
        } footer: {
            Text(String(format: "In play, flag points come from the course file. A range more than %.0f m from a published flag is refused.", Safety.limits.flagGateTolerance))
        }
    }

    private var logSection: some View {
        Section("Log for the field test") {
            LabeledContent("Taped distance") {
                HStack {
                    TextField("m", value: $trueDistance, format: .number.precision(.fractionLength(2)))
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(maxWidth: 90)
                    Text("m")
                }
            }
            if let r = report, let t = trueDistance, t > 0 {
                let e = r.distance - t
                Text(String(format: "Error %+.2f m (%+.1f%%)", e, e / t * 100)).monospacedDigit()
                    .foregroundStyle(abs(e) <= max(2 * r.distanceSigma, 0.05) ? .green : .orange)
            }
            TextField("Note", text: $note)
            Button(logged ? "Logged" : "Log this ranging") {
                guard let r = report else { return }
                rangingLog.add(RangingRecord(report: r, sightings: session.sightings, trueDistance: trueDistance,
                                             gateMiss: gate?.miss, poleHeight: poleHeight,
                                             cameraHeight: cameraHeight, note: note))
                logged = true
            }
            .disabled(logged)
        }
    }
}

/// Full-screen marking for one AR photo. Runs as a sheet so the AR session keeps tracking underneath.
struct MarkPhotoSheet: View {
    let frame: FrozenFrame
    let done: (CGPoint, CGPoint) -> Void
    let cancel: () -> Void
    @State private var tip: CGPoint?
    @State private var base: CGPoint?

    var body: some View {
        NavigationStack {
            ScrollView {
                PoleMarker(frame: frame, tip: $tip, base: $base, photoHeight: 420).padding()
            }
            .navigationTitle("Mark tip and base")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Discard", action: cancel) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use photo") { if let tip, let base { done(tip, base) } }
                        .disabled(tip == nil || base == nil)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

/// The live view: the AR camera on a phone, or the simulated scene from the phone's current spot.
struct CaptureFeedView: View {
    @ObservedObject var session: RangingSession

    var body: some View {
        if let ar = session.source as? ARKitRangingSource {
            ARViewContainer(arView: ar.arView)
        } else if let sim = session.source as? SimulatedRangingSource, let image = sim.preview() {
            // Re-rendered whenever the session changes, e.g. after each photo moves the phone.
            Image(decorative: image, scale: 1).resizable().scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        } else {
            Color.black
        }
    }
}

struct ARViewContainer: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}
