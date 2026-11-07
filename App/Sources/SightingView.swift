import SwiftUI
import RangingKit

/// Field test for milestone 1: photograph the pole from a taped distance, mark its tip and
/// base, and log how close the size range comes.
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
    enum Target: String, CaseIterable { case tip = "Tip", base = "Base" }

    let frame: FrozenFrame
    let retake: () -> Void

    @EnvironmentObject private var log: FieldLogStore
    @AppStorage(Settings.poleHeightKey) private var poleHeight = Settings.defaultPoleHeight
    @AppStorage(Settings.cameraHeightKey) private var cameraHeight = Settings.defaultCameraHeight
    @State private var target: Target = .tip
    @State private var tip: CGPoint?
    @State private var base: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var trueDistance: Double?
    @State private var note = ""
    @State private var logged = false

    private let loupeSource: CGFloat = 64   // image pixels shown in the loupe
    private let loupeSize: CGFloat = 220    // points on screen

    private var imageSize: CGSize { CGSize(width: frame.image.width, height: frame.image.height) }

    private var sample: FieldSample? {
        guard let tip, let base else { return nil }
        return FieldSample(lens: frame.lens, approximateIntrinsics: frame.approximateIntrinsics, trueDistance: trueDistance,
                           poleHeight: poleHeight, cameraHeight: cameraHeight,
                           tip: frame.bufferPoint(tip), base: frame.bufferPoint(base),
                           intrinsics: frame.intrinsics, note: note)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                photo
                Picker("Marking", selection: $target) {
                    ForEach(Target.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                loupe
                results
            }
            .padding()
        }
    }

    // Tap anywhere on the photo to drop the active marker.
    private var photo: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width / imageSize.width, geo.size.height / imageSize.height)
            let shown = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
            let origin = CGPoint(x: (geo.size.width - shown.width) / 2, y: (geo.size.height - shown.height) / 2)
            ZStack(alignment: .topLeading) {
                Image(decorative: frame.image, scale: 1)
                    .resizable()
                    .frame(width: shown.width, height: shown.height)
                    .offset(x: origin.x, y: origin.y)
                ForEach([(tip, Color.orange), (base, Color.cyan)].indices, id: \.self) { i in
                    let pair = [(tip, Color.orange), (base, Color.cyan)][i]
                    if let p = pair.0 {
                        Circle().stroke(pair.1, lineWidth: 2).frame(width: 14, height: 14)
                            .position(x: origin.x + p.x * scale, y: origin.y + p.y * scale)
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { loc in
                let p = CGPoint(x: (loc.x - origin.x) / scale, y: (loc.y - origin.y) / scale)
                guard p.x >= 0, p.y >= 0, p.x < imageSize.width, p.y < imageSize.height else { return }
                set(p)
            }
        }
        .frame(height: 360)
    }

    // Magnified view of the active marker; drag to nudge it a pixel at a time.
    @ViewBuilder private var loupe: some View {
        if let p = current, let crop = crop(around: p) {
            ZStack {
                Image(decorative: crop.image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .frame(width: loupeSize, height: loupeSize)
                Path { path in
                    let c = CGPoint(x: (p.x - crop.origin.x) / loupeSource * loupeSize,
                                    y: (p.y - crop.origin.y) / loupeSource * loupeSize)
                    path.move(to: CGPoint(x: c.x - 14, y: c.y)); path.addLine(to: CGPoint(x: c.x + 14, y: c.y))
                    path.move(to: CGPoint(x: c.x, y: c.y - 14)); path.addLine(to: CGPoint(x: c.x, y: c.y + 14))
                }
                .stroke(target == .tip ? Color.orange : Color.cyan, lineWidth: 1.5)
            }
            .frame(width: loupeSize, height: loupeSize)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if dragStart == nil { dragStart = p }
                    let k = loupeSource / loupeSize / 2 // half speed for fine control
                    if let s = dragStart {
                        set(CGPoint(x: (s.x + g.translation.width * k).rounded(), y: (s.y + g.translation.height * k).rounded()))
                    }
                }
                .onEnded { _ in dragStart = nil })
            Text(String(format: "%@ at (%.0f, %.0f). Drag in the loupe to nudge.", target.rawValue, p.x, p.y))
                .font(.footnote).foregroundStyle(.secondary)
        } else {
            Text("Tap the \(target.rawValue.lowercased()) of the pole in the photo.")
                .font(.footnote).foregroundStyle(.secondary)
        }
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

    private var current: CGPoint? { target == .tip ? tip : base }

    private func set(_ p: CGPoint) {
        let clamped = CGPoint(x: min(max(p.x, 0), imageSize.width - 1), y: min(max(p.y, 0), imageSize.height - 1))
        if target == .tip { tip = clamped } else { base = clamped }
        logged = false
    }

    private func crop(around p: CGPoint) -> (image: CGImage, origin: CGPoint)? {
        let half = loupeSource / 2
        let x = min(max(p.x - half, 0), imageSize.width - loupeSource)
        let y = min(max(p.y - half, 0), imageSize.height - loupeSource)
        let rect = CGRect(x: x.rounded(.down), y: y.rounded(.down), width: loupeSource, height: loupeSource)
        guard let img = frame.image.cropping(to: rect) else { return nil }
        return (img, rect.origin)
    }
}
