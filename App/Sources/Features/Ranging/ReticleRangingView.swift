import SwiftUI
import RangingKit
import CoreGeo
import SafetyKit

/// The main ranging method: hold the crosshair on the pole's base, rough the dial in on the live view,
/// freeze a full-resolution still, fine-match the plumb line's top to the pole's top on it, and lock.
/// No tapping.
///
/// Live video is 1920 × 1440 on every iPhone; the still is the phone's full sensor resolution (about
/// 4032 × 3024), which halves the range error and removes hand shake from the match.
///
/// The dial sets the line's length in sensor pixels (`ReticleRange`), which is then drawn in screen
/// points. Pinch zoom enlarges the feed and the line together, so it never changes the range.
/// Ranging inside a fire mission: the hole's pole height and flag, and a button that hands the lock back.
struct MissionRangingContext {
    var title: String
    var poleHeight: Double
    var flag: GeoPoint
    var onUse: (ReticleLock) -> Void
}

struct ReticleRangingView: View {
    /// Set when a fire mission opens the ranging; nil for the Tools field test.
    var mission: MissionRangingContext? = nil

    @StateObject private var session = RangingSession.make()
    @StateObject private var motion = MotionReader()
    @EnvironmentObject private var reticleLog: ReticleLogStore
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @AppStorage(Settings.cameraHeightKey) private var cameraHeight = Settings.defaultCameraHeight
    @AppStorage(Settings.flagLatKey) private var flagLat = 0.0
    @AppStorage(Settings.flagLonKey) private var flagLon = 0.0

    @State private var dialRange = 50.0
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var lock: ReticleLock?
    @State private var gate: Safety.FlagCheck?
    @State private var lockProblem: String?
    @State private var simImage: CGImage?
    @State private var trueDistance: Double?
    @State private var note = ""
    @State private var logged = false
    /// The full-resolution still being matched, with the tilt, plumb direction and aim at the moment of Freeze.
    @State private var still: FrozenFrame?
    @State private var stillAngleBelow = 0.0
    @State private var stillUp = CGVector(dx: 0, dy: -1)
    @State private var stillAim: CaptureAim?
    /// Zoom anchor on the frozen still, view fractions: the middle of the line when frozen.
    @State private var stillAnchor = UnitPoint.center
    @State private var freezing = false

    private static let dialRange: ClosedRange<Double> = 5...100
    private static let polePresets: [(label: String, feet: Double)] = [("8 ft", 8), ("10 ft", 10), ("12 ft", 12)]

    private var flagPoint: GeoPoint? {
        if let mission { return mission.flag }
        return flagLat == 0 && flagLon == 0 ? nil : GeoPoint(latitude: flagLat, longitude: flagLon)
    }

    /// The hole's pole in a mission; the Tools setting otherwise.
    private var activePoleHeight: Double { mission?.poleHeight ?? poleHeight }

    /// CoreMotion on a phone; the capture source's own aim in the Simulator.
    private var angleBelowLevel: Double? {
        if let g = motion.gravity { return MotionReader.angleBelowLevel(gravity: g) }
        return session.source.liveAim()?.angleBelowLevel
    }

    /// Intrinsics of the image being matched: the frozen still if there is one, else the live feed.
    private var activeIntrinsics: Intrinsics? { still?.intrinsics ?? session.source.liveIntrinsics() }

    /// The locked reticle, or the one for the image being matched.
    private var reticle: ReticleRange? {
        if let lock { return lock.reticle }
        guard let k = activeIntrinsics else { return nil }
        // In portrait the screen's vertical runs along the buffer's x axis, so the line uses fx.
        return ReticleRange(focalPixels: k.fx, poleHeight: activePoleHeight,
                            angleBelowLevel: still != nil ? stillAngleBelow : (angleBelowLevel ?? 0))
    }

    private var shownRange: Double { lock?.range ?? dialRange }

    var body: some View {
        VStack(spacing: 0) {
            feed.frame(height: 380).clipped()
            List {
                dialSection
                if let lock { resultSection(lock) }
                flagSection
                if let mission, let lock { useSection(mission, lock) }
                if lock != nil && mission == nil { logSection }
            }
        }
        .navigationTitle(mission?.title ?? "Range the pole")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar) // the floating tab bar would cover the dial
        .onAppear {
            if let sim = session.source as? SimulatedRangingSource {
                sim.aimAtBase = true
                simImage = sim.preview(scale: 0.6)
            }
            session.start()
            motion.start()
        }
        .onDisappear {
            session.pause()
            motion.stop()
        }
    }

    // MARK: Camera feed and reticle

    private var feed: some View {
        GeometryReader { geo in
            let totalZoom = zoom * pinch
            // Live: zoom about the crosshair. Frozen: about the middle of the line, so the base and the
            // top stay on screen together while zoomed in to fine-match.
            let anchor = still != nil ? stillAnchor : .center
            let a = CGPoint(x: anchor.x * geo.size.width, y: anchor.y * geo.size.height)
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let base = CGPoint(x: a.x + (c.x - a.x) * totalZoom, y: a.y + (c.y - a.y) * totalZoom)
            ZStack {
                cameraLayer
                    .frame(width: geo.size.width, height: geo.size.height)
                    .scaleEffect(totalZoom, anchor: anchor)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                ReticleOverlay(base: base,
                               lineLength: linePoints(in: geo.size) * totalZoom,
                               up: still != nil ? stillUp : MotionReader.plumbUp(gravity: motion.gravity),
                               locked: lock != nil)
                    .allowsHitTesting(false)
                VStack {
                    HStack {
                        Text(feedLabel)
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                        Button {
                            zoom = zoom >= 4 ? 1 : zoom * 2
                        } label: {
                            Text(String(format: "%.0f×", totalZoom))
                                .font(.footnote.weight(.semibold)).monospacedDigit()
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                        .accessibilityLabel("View zoom")
                    }
                    Spacer()
                }
                .padding(8)
            }
            .contentShape(Rectangle())
            .gesture(MagnificationGesture()
                .updating($pinch) { value, state, _ in state = value }
                .onEnded { value in zoom = min(8, max(1, zoom * value)) })
        }
        .background(Color.black)
    }

    private var feedLabel: String {
        if let k = still?.intrinsics { return "Frozen · \(k.width)×\(k.height)" }
        return session.source.isSimulated ? "Simulated · \(session.tracking.label)" : session.tracking.label
    }

    @ViewBuilder private var cameraLayer: some View {
        ZStack {
            if let ar = session.source as? ARKitRangingSource {
                ARViewContainer(arView: ar.arView)
            } else if let simImage {
                Image(decorative: simImage, scale: 1).resizable().scaledToFill()
            } else {
                Color.black
            }
            if let still {
                Image(decorative: still.image, scale: 1).resizable().scaledToFill()
            }
        }
    }

    /// Screen points for the dial's range at zoom 1. The feed is aspect-filled from the landscape
    /// buffer shown upright, so one sensor pixel is `max(viewW / bufferH, viewH / bufferW)` points.
    private func linePoints(in size: CGSize) -> CGFloat {
        guard let reticle, let k = activeIntrinsics else { return 0 }
        let perPixel = max(size.width / CGFloat(k.height), size.height / CGFloat(k.width))
        return CGFloat(reticle.linePixels(range: shownRange)) * perPixel
    }

    // MARK: Dial and lock

    private var dialSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(Units.metres(shownRange)).font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                    Text(Units.yards(shownRange)).foregroundStyle(.secondary).monospacedDigit()
                    Spacer()
                    if let reticle {
                        Text(String(format: "± %@", Units.metres(reticle.sigma(range: shownRange))))
                            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                HStack {
                    Button { nudge(-0.1) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Range down 0.1 m")
                    Slider(value: $dialRange, in: Self.dialRange, step: 0.1) { Text("Range") }
                    Button { nudge(0.1) } label: { Image(systemName: "plus.circle") }
                        .buttonStyle(.borderless).accessibilityLabel("Range up 0.1 m")
                }
                .disabled(lock != nil)
                if let reticle {
                    Text(String(format: "Line %.0f px on the sensor · %.1f° below level", reticle.linePixels(range: shownRange),
                                reticle.angleBelowLevel))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let k = activeIntrinsics, lock == nil {
                        Text(still != nil ? "Matching on the \(k.width)×\(k.height) still"
                                          : "Live \(k.width)×\(k.height) video · Freeze for the full-resolution still")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            LabeledContent("Pole height") {
                Menu {
                    ForEach(Self.polePresets, id: \.label) { p in
                        Button(p.label) { poleHeight = p.feet * 0.3048 }
                    }
                } label: {
                    Text("\(Units.feetInches(activePoleHeight)) (\(String(format: "%.3f m", activePoleHeight)))").monospacedDigit()
                }
                .disabled(lock != nil || mission != nil)
            }
            if lock == nil {
                if still == nil {
                    Button {
                        freeze()
                    } label: {
                        Label(freezing ? "Freezing…" : "Freeze", systemImage: "camera.aperture")
                            .font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.trackingReady || freezing)
                    Button("Lock on the live view") { lockRange() }
                        .disabled(!session.trackingReady)
                } else {
                    Button {
                        lockRange()
                    } label: {
                        Label("Lock", systemImage: "lock.fill").font(.headline).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Back to live") { unfreeze() }
                }
                if let lockProblem {
                    Text(lockProblem).font(.footnote).foregroundStyle(.orange)
                }
            } else {
                Button("Re-range", role: .destructive) { unlock() }
            }
        } header: {
            Text("Range dial")
        } footer: {
            Text("Hold the crosshair on the pole's base and turn the dial roughly to the top of the orange band. Freeze, pinch to zoom on the still, fine-match the line's top to the band's top, then lock. Zoom never changes the range.")
        }
    }

    /// Takes the full-resolution still, keeping the tilt, plumb direction and aim of this moment.
    private func freeze() {
        guard let aim = session.source.liveAim() else { lockProblem = "No compass bearing yet. Wait for tracking, then freeze again."; return }
        let below = angleBelowLevel ?? aim.angleBelowLevel
        let up = MotionReader.plumbUp(gravity: motion.gravity)
        freezing = true
        lockProblem = nil
        session.source.captureStill { frame in
            freezing = false
            guard let frame else { lockProblem = "The camera gave no still. Lock on the live view instead."; return }
            still = frame
            stillAngleBelow = below
            stillUp = up
            stillAim = aim
            // Zoom about the middle of the line at the dial's current range.
            let k = frame.intrinsics
            let r = ReticleRange(focalPixels: k.fx, poleHeight: activePoleHeight, angleBelowLevel: below)
            let viewH = 380.0, viewW = UIScreen.main.bounds.width
            let perPixel = max(viewW / Double(k.height), viewH / Double(k.width))
            let half = r.linePixels(range: dialRange) * perPixel / 2
            stillAnchor = UnitPoint(x: 0.5 + up.dx * half / viewW, y: 0.5 + up.dy * half / viewH)
            zoom = 1
        }
    }

    private func unfreeze() {
        still = nil
        stillAim = nil
        zoom = 1
    }

    private func nudge(_ by: Double) {
        dialRange = min(Self.dialRange.upperBound, max(Self.dialRange.lowerBound, (dialRange + by) * 10).rounded() / 10)
    }

    private func lockRange() {
        guard let k = activeIntrinsics else { lockProblem = "No camera frame yet. Wait a moment and lock again."; return }
        guard let aim = stillAim ?? session.source.liveAim() else { lockProblem = "No compass bearing yet. Wait for tracking, then lock again."; return }
        guard let location = session.currentLocation else { lockProblem = "Waiting for GPS. Lock again once it has a fix."; return }
        let below = still != nil ? stillAngleBelow : (angleBelowLevel ?? aim.angleBelowLevel)
        let l = ReticleLock(reticle: ReticleRange(focalPixels: k.fx, poleHeight: activePoleHeight, angleBelowLevel: below),
                            range: dialRange, bearing: aim.bearing, cameraHeight: cameraHeight,
                            location: location, horizontalAccuracy: session.horizontalAccuracy,
                            imageWidth: k.width, imageHeight: k.height)
        let en = l.eastNorth
        lock = l
        gate = Safety.checkFlag(lie: l.location, east: en.east, north: en.north, flag: flagPoint)
        lockProblem = nil
        logged = false
    }

    private func unlock() {
        unfreeze()
        lock = nil
        gate = nil
        logged = false
    }

    private func resultSection(_ l: ReticleLock) -> some View {
        Section("Locked") {
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Units.metres(l.range))  ·  \(Units.yards(l.range))")
                    .font(.system(size: 28, weight: .bold, design: .rounded)).monospacedDigit()
                Text(String(format: "± %@ (1σ, ±1 px at the base and the top)", Units.metres(l.sigma)))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            LabeledContent("Height difference", value: String(format: "%+.2f m %@", l.heightDifference,
                                                               l.heightDifference >= 0 ? "(uphill)" : "(downhill)"))
            LabeledContent("Bearing", value: String(format: "%.1f°", l.bearing))
            LabeledContent("Angle below level", value: String(format: "%.2f°", l.angleBelowLevel))
            if let w = l.imageWidth, let h = l.imageHeight {
                LabeledContent("Matched on", value: "\(w)×\(h)")
            }
            LabeledContent("GPS", value: String(format: "%.6f, %.6f%@", l.location.latitude, l.location.longitude,
                                                 l.horizontalAccuracy.map { String(format: " ±%.0f m", $0) } ?? ""))
        }
    }

    private var flagSection: some View {
        Section {
            if let g = gate {
                if let miss = g.miss {
                    HStack {
                        Text(String(format: "Ranged pole is %.1f m from the flag point", miss))
                        Spacer()
                        Image(systemName: g.verdict.isAllowed ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(g.verdict.isAllowed ? .green : .red)
                    }
                }
                ForEach(Array(g.verdict.reasons.enumerated()), id: \.offset) { _, reason in
                    Text(reason.description).font(.footnote).foregroundStyle(.red)
                }
            } else if flagPoint == nil {
                Text("No flag point saved. Stand at the pole and save one to test the flag check.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                Text("Lock to run the flag check.").font(.footnote).foregroundStyle(.secondary)
            }
            if mission == nil {
                Button("Save my GPS position as the flag point") {
                    if let c = session.currentLocation { flagLat = c.latitude; flagLon = c.longitude }
                }
                .disabled(session.currentLocation == nil || lock != nil)
            }
            if mission == nil, let sim = session.source as? SimulatedRangingSource {
                Button("Use the simulated scene's flag point") {
                    flagLat = sim.flagPoint.latitude
                    flagLon = sim.flagPoint.longitude
                }
                .disabled(lock != nil)
            }
            if let a = session.horizontalAccuracy {
                Text(String(format: "GPS accuracy now ±%.0f m", a)).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("Flag check")
        } footer: {
            Text(String(format: "GPS position + bearing + range places the pole. A lock more than %.0f m from a published flag is refused.", Safety.limits.flagGateTolerance))
        }
    }

    private func useSection(_ mission: MissionRangingContext, _ lock: ReticleLock) -> some View {
        Section {
            Button {
                mission.onUse(lock)
            } label: {
                Label("Use this range", systemImage: "checkmark.circle.fill").font(.headline).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(gate?.verdict.isAllowed != true)
        } footer: {
            Text("Only a range that lands on this hole's flag goes to the firing computer.")
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
            if let l = lock, let t = trueDistance, t > 0 {
                let e = l.range - t
                Text(String(format: "Error %+.2f m (%+.1f%%)", e, e / t * 100)).monospacedDigit()
                    .foregroundStyle(abs(e) <= max(2 * l.sigma, 0.05) ? .green : .orange)
            }
            TextField("Note", text: $note)
            Button(logged ? "Logged" : "Log this lock") {
                guard let l = lock else { return }
                reticleLog.add(ReticleRecord(lock: l, trueDistance: trueDistance, gateMiss: gate?.miss, note: note))
                logged = true
            }
            .disabled(logged)
        }
    }
}

/// Crosshair at the centre of the view, with a plumb line rising from it to the dial's length.
struct ReticleOverlay: View {
    /// Where the crosshair sits on screen (the pole's base); the view's centre unless zoomed off-centre.
    var base: CGPoint? = nil
    /// Line length, screen points.
    var lineLength: CGFloat
    /// Unit "up" direction on screen (y down), from gravity.
    var up: CGVector
    var locked: Bool

    var body: some View {
        Canvas { ctx, size in
            let c = base ?? CGPoint(x: size.width / 2, y: size.height / 2)
            let side = CGVector(dx: -up.dy, dy: up.dx) // perpendicular to the line
            let top = CGPoint(x: c.x + up.dx * lineLength, y: c.y + up.dy * lineLength)
            func seg(_ a: CGPoint, _ b: CGPoint) -> Path { var p = Path(); p.move(to: a); p.addLine(to: b); return p }
            func along(_ from: CGPoint, _ v: CGVector, _ t: CGFloat) -> CGPoint { CGPoint(x: from.x + v.dx * t, y: from.y + v.dy * t) }

            var reticle = Path()
            // Crosshair with a gap on the base.
            reticle.addPath(seg(along(c, side, -18), along(c, side, -4)))
            reticle.addPath(seg(along(c, side, 4), along(c, side, 18)))
            reticle.addPath(seg(along(c, up, -4), along(c, up, -16)))
            // Plumb line and its top tick.
            reticle.addPath(seg(c, top))
            reticle.addPath(seg(along(top, side, -7), along(top, side, 7)))

            ctx.stroke(reticle, with: .color(.black.opacity(0.75)), lineWidth: 3)
            ctx.stroke(reticle, with: .color(locked ? .green : .white), lineWidth: 1.2)
        }
    }
}
