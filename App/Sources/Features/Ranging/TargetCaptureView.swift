import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import CoreGeo
import RangingKit

/// Target capture for the 3D field: a few full-resolution stills of one target from different
/// spots, each with its ARKit pose, lens data and GPS, and a scale stick of known length standing in
/// every frame. Tap the target and two of the stick's bands on each still; after two shots the
/// target's position, its ±, and the stick's scale check show. Saved as a bundle (JPEGs with GPS in
/// their EXIF, plus `capture.json`) for the Theater host.
struct TargetCaptureView: View {
    @StateObject private var session = RangingSession.make()
    @AppStorage("targetCaptureStick") private var stickChoice = 0
    @State private var shots: [TargetSighting] = []
    @State private var stills: [UUID: CGImage] = [:]
    @State private var marking: Marking?
    @State private var freezing = false
    @State private var problem: String?
    @State private var savedFolder: URL?
    @State private var sendingToTheater = false
    /// One ID per saved capture: its files land in one folder on the Theater.
    @State private var captureGroup = UUID()
    @EnvironmentObject private var theater: TheaterLink
    @EnvironmentObject private var courses: CourseStore
    @State private var simImage: CGImage?

    private static let sticks: [ScaleStick] = [.meterQuarters, .twoMeterHalves]
    private var stick: ScaleStick { Self.sticks[min(max(0, stickChoice), Self.sticks.count - 1)] }
    private var fix: TargetFix? { shots.count >= 2 ? TargetSolver.solve(shots, stick: stick) : nil }

    /// A still being marked: the target first, then the stick's bottom band, then its top band.
    struct Marking {
        var frame: FrozenFrame
        var location: GeoPoint?
        var accuracy: Double?
        var target: CGPoint?
        var bottom: CGPoint?
        var top: CGPoint?
        var nextPrompt: String {
            if target == nil { return "Tap the target" }
            if bottom == nil { return "Tap the stick's bottom band" }
            if top == nil { return "Tap the stick's top band" }
            return "Use this shot, or tap Redo"
        }
        var complete: Bool { target != nil && bottom != nil && top != nil }
    }

    var body: some View {
        ZStack {
            if let marking {
                TargetMarkingView(marking: Binding(get: { marking }, set: { self.marking = $0 }))
                    .ignoresSafeArea(edges: .bottom)
            } else {
                feed.ignoresSafeArea(edges: .bottom)
                ReticleOverlay(lineLength: 0, up: CGVector(dx: 0, dy: -1), locked: false)
                    .allowsHitTesting(false).ignoresSafeArea(edges: .bottom)
            }
            controls.environment(\.colorScheme, .dark)
        }
        .background(Color.black)
        .navigationTitle("Target capture")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Scale stick", selection: $stickChoice) {
                        ForEach(Self.sticks.indices, id: \.self) { Text(Self.sticks[$0].name).tag($0) }
                    }
                    Button("Start over", role: .destructive) { reset() }.disabled(shots.isEmpty)
                } label: { Image(systemName: "ruler") }
            }
        }
        .onAppear {
            if let sim = session.source as? SimulatedRangingSource { simImage = sim.preview(scale: 0.6) }
            session.start()
        }
        .onDisappear { session.pause() }
        .sheet(isPresented: $sendingToTheater) {
            if let folder = savedFolder {
                NavigationStack {
                    TheaterSendView(title: "Send capture", summary: Self.files(in: folder).map(\.lastPathComponent),
                                    payloads: { [group = captureGroup, course = courses.loaded?.result.course?.id ?? courses.practiceCourse?.id] in
                                        Self.files(in: folder).map { .file($0, kind: .capture, group: group, courseID: course) }
                                    })
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { sendingToTheater = false } } }
                }
                .environmentObject(theater)
            }
        }
    }

    /// A saved capture's files to send: the shots, then capture.json.
    static func files(in folder: URL) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return all.filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { ($0.lastPathComponent == "capture.json" ? 1 : 0, $0.lastPathComponent) < ($1.lastPathComponent == "capture.json" ? 1 : 0, $1.lastPathComponent) }
    }

    /// The live camera, filled into the screen and clipped to it (an aspect-filled image would
    /// otherwise widen the whole layout).
    private var feed: some View {
        GeometryReader { g in
            Group {
                if let ar = session.source as? ARKitRangingSource {
                    ARViewContainer(arView: ar.arView)
                } else if let simImage {
                    Image(decorative: simImage, scale: 1).resizable().scaledToFill()
                } else {
                    Color.black
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .clipped()
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 44)
            HStack {
                VStack(spacing: 10) {
                    if marking == nil {
                        HUDButton(title: freezing ? "Taking" : "Shot \(shots.count + 1)", systemImage: "camera.aperture",
                                  prominent: true) { takeShot() }
                            .disabled(!session.trackingReady || freezing)
                    } else {
                        HUDButton(title: "Use shot", systemImage: "checkmark", prominent: true) { useShot() }
                            .disabled(marking?.complete != true)
                        HUDButton(title: "Redo", systemImage: "arrow.uturn.backward") { redoMark() }
                        HUDButton(title: "Discard", systemImage: "trash") { marking = nil }
                    }
                    if marking == nil, !shots.isEmpty {
                        HUDButton(title: "Save", systemImage: "square.and.arrow.down") { save() }
                            .disabled(fix == nil)
                    }
                }
                Spacer()
            }
            Spacer(minLength: 8)
            readout
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var readout: some View {
        HUDPanel {
            VStack(alignment: .leading, spacing: 4) {
                if let marking {
                    Text(marking.nextPrompt).font(.headline)
                    Text("Pinch to zoom in for a precise tap; drag to move around.").font(.caption).foregroundStyle(.secondary)
                    Text("Shot \(shots.count + 1). Stick: \(stick.name).").font(.footnote).foregroundStyle(.secondary)
                } else if let fix {
                    result(fix)
                } else {
                    Text(shots.isEmpty ? "Crosshair on the target, with the scale stick standing in frame. Take shot 1."
                                       : "Walk a few metres to one side, keep the target and the stick in frame, and take shot 2.")
                        .font(.footnote)
                }
                if !shots.isEmpty, marking == nil {
                    Text("\(shots.count) shot\(shots.count == 1 ? "" : "s")" + (session.horizontalAccuracy.map { String(format: " · GPS ±%.0f m", $0) } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let problem { Text(problem).font(.footnote).foregroundStyle(.orange) }
                if let savedFolder {
                    HStack(spacing: 16) {
                        Button { sendingToTheater = true } label: { Label("Send to Theater", systemImage: "theatermasks") }
                        ShareLink(item: savedFolder) { Label("Share", systemImage: "square.and.arrow.up") }
                    }
                    .font(.footnote)
                }
            }
        }
    }

    @ViewBuilder private func result(_ f: TargetFix) -> some View {
        if let loc = f.location {
            Text(String(format: "%.6f, %.6f", loc.latitude, loc.longitude)).font(.headline).monospacedDigit()
        }
        Text(String(format: "± %.2f m · rays %.0f° apart · %+.1f m from eye height", f.missRMS, f.spreadDegrees, f.heightFromCameras))
            .font(.footnote).monospacedDigit()
        if let m = f.measuredStick, let k = f.knownStick {
            Text(String(format: "Stick read %.2f m of %.2f m%@", m, k,
                        f.scale == 1 && abs(m - k) / max(k, 0.01) > TargetSolver.maxScaleCorrection
                            ? ": too far off to be drift, check the bands you tapped"
                            : String(format: ", scale corrected %+.1f%%", f.scaleCorrectionPercent)))
                .font(.footnote).foregroundStyle(f.scale == 1 && abs(m - k) / max(k, 0.01) > TargetSolver.maxScaleCorrection ? .orange : .secondary)
        }
        if !f.wellConditioned {
            Text("The shots are too close together for a good depth. Take another a few metres further to the side.")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    // MARK: Actions

    private func takeShot() {
        freezing = true
        problem = nil
        savedFolder = nil
        session.source.captureStill { frame in
            freezing = false
            guard let frame, frame.pose != nil else { problem = "No tracked still. Hold steady and try again."; return }
            marking = Marking(frame: frame, location: session.currentLocation, accuracy: session.horizontalAccuracy)
        }
    }

    private func redoMark() {
        guard var m = marking else { return }
        if m.top != nil { m.top = nil } else if m.bottom != nil { m.bottom = nil } else { m.target = nil }
        marking = m
    }

    private func useShot() {
        guard let m = marking, m.complete, let pose = m.frame.pose, let t = m.target, let b = m.bottom, let top = m.top else { return }
        let id = UUID()
        let shot = TargetSighting(id: id, pose: pose, intrinsics: m.frame.intrinsics, target: m.frame.bufferPixel(t),
                                  stickMarks: [0: m.frame.bufferPixel(b), stick.marks.count - 1: m.frame.bufferPixel(top)],
                                  location: m.location, horizontalAccuracy: m.accuracy, imageFile: "shot-\(shots.count + 1).jpg")
        shots.append(shot)
        stills[id] = m.frame.image
        marking = nil
    }

    private func reset() {
        shots = []
        stills = [:]
        marking = nil
        savedFolder = nil
        problem = nil
    }

    /// Writes `Documents/Captures/<date>/`: each still as a JPEG with its GPS in EXIF, and `capture.json`.
    private func save() {
        guard let f = fix else { return }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Captures/target-\(stamp)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for s in shots {
                guard let image = stills[s.id], let name = s.imageFile else { continue }
                try Self.writeJPEG(image, to: dir.appendingPathComponent(name), location: s.location, accuracy: s.horizontalAccuracy, date: s.date)
            }
            let bundle = TargetCaptureBundle(stick: stick, shots: shots, target: f.location,
                                             targetPlusMinus: f.missRMS, spreadDegrees: f.spreadDegrees,
                                             scale: f.scale, measuredStick: f.measuredStick, knownStick: f.knownStick)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(bundle).write(to: dir.appendingPathComponent("capture.json"), options: .atomic)
            savedFolder = dir
            captureGroup = UUID()
            problem = nil
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
        }
    }

    static func writeJPEG(_ image: CGImage, to url: URL, location: GeoPoint?, accuracy: Double?, date: Date) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        if let p = location {
            var gps: [CFString: Any] = [
                kCGImagePropertyGPSLatitude: abs(p.latitude),
                kCGImagePropertyGPSLatitudeRef: p.latitude >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude: abs(p.longitude),
                kCGImagePropertyGPSLongitudeRef: p.longitude >= 0 ? "E" : "W",
            ]
            if let accuracy { gps[kCGImagePropertyGPSHPositioningError] = accuracy }
            props[kCGImagePropertyGPSDictionary] = gps
        }
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        props[kCGImagePropertyExifDictionary] = [kCGImagePropertyExifDateTimeOriginal: f.string(from: date)]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// `capture.json`: everything needed to redo the solve on the host.
struct TargetCaptureBundle: Codable {
    var format = 1
    var stick: ScaleStick
    var shots: [TargetSighting]
    var target: GeoPoint?
    var targetPlusMinus: Double
    var spreadDegrees: Double
    var scale: Double
    var measuredStick: Double?
    var knownStick: Double?
}

/// The frozen still, fitted to the screen, taking taps for the target and the stick's bands.
private struct TargetMarkingView: View {
    @Binding var marking: TargetCaptureView.Marking
    /// Pinch to zoom (up to 10×) and drag to pan, so a far target can be tapped to the pixel.
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let fit = Fit(image: marking.frame.image, in: geo.size, zoom: min(10, max(1, zoom * pinch)),
                          pan: CGSize(width: pan.width + drag.width, height: pan.height + drag.height))
            ZStack(alignment: .topLeading) {
                Color.black
                Image(decorative: marking.frame.image, scale: 1).resizable()
                    .frame(width: fit.shown.width, height: fit.shown.height)
                    .offset(x: fit.origin.x, y: fit.origin.y)
                ForEach(Array(marks.enumerated()), id: \.offset) { _, m in
                    MarkDot(color: m.color, label: m.label).position(fit.screen(m.point))
                }
                if zoom > 1 {
                    Button("1×") { withAnimation { zoom = 1; pan = .zero } }
                        .font(.footnote.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .position(x: geo.size.width - 36, y: 70)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture { location in
                let p = fit.image(location)
                guard p.x >= 0, p.y >= 0, p.x < fit.size.width, p.y < fit.size.height else { return }
                if marking.target == nil { marking.target = p }
                else if marking.bottom == nil { marking.bottom = p }
                else if marking.top == nil { marking.top = p }
            }
            .simultaneousGesture(MagnificationGesture()
                .updating($pinch) { v, s, _ in s = v }
                .onEnded { v in zoom = min(10, max(1, zoom * v)); if zoom == 1 { pan = .zero } })
            .simultaneousGesture(DragGesture(minimumDistance: 12)
                .updating($drag) { v, s, _ in s = v.translation }
                .onEnded { v in pan.width += v.translation.width; pan.height += v.translation.height })
        }
    }

    /// The still fitted inside the view, then zoomed about the view's centre and panned:
    /// image pixels ↔ screen points.
    struct Fit {
        let size: CGSize, scale: CGFloat, shown: CGSize, origin: CGPoint
        init(image: CGImage, in view: CGSize, zoom: CGFloat = 1, pan: CGSize = .zero) {
            size = CGSize(width: image.width, height: image.height)
            scale = min(view.width / size.width, view.height / size.height) * zoom
            shown = CGSize(width: size.width * scale, height: size.height * scale)
            origin = CGPoint(x: (view.width - shown.width) / 2 + pan.width, y: (view.height - shown.height) / 2 + pan.height)
        }
        func screen(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
        func image(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - origin.x) / scale, y: (p.y - origin.y) / scale) }
    }

    private var marks: [(point: CGPoint, color: Color, label: String)] {
        var m: [(CGPoint, Color, String)] = []
        if let t = marking.target { m.append((t, .red, "target")) }
        if let b = marking.bottom { m.append((b, .yellow, "bottom")) }
        if let t = marking.top { m.append((t, .yellow, "top")) }
        return m
    }
}

private struct MarkDot: View {
    let color: Color
    let label: String
    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle().stroke(.black, lineWidth: 3).frame(width: 18, height: 18)
                Circle().stroke(color, lineWidth: 1.5).frame(width: 18, height: 18)
                Rectangle().fill(color).frame(width: 1, height: 26)
                Rectangle().fill(color).frame(width: 26, height: 1)
            }
            Text(label).font(.caption2.weight(.semibold)).foregroundStyle(color)
                .padding(.horizontal, 4).background(.black.opacity(0.6), in: Capsule())
        }
    }
}
