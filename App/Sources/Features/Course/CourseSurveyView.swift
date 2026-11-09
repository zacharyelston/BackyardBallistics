import SwiftUI
import CoreLocation
import CoreGeo
import CourseKit
import GroupKit
import SafetyKit

/// A survey in progress: one hole's pole, its firing point and the boundary corners, kept between
/// launches so the walk around the property can be paused.
struct CourseSurvey: Codable, Equatable {
    struct Fix: Codable, Equatable {
        var point: GeoPoint
        /// Horizontal accuracy of the averaged fix, metres.
        var accuracy: Double
        var samples: Int
    }

    var name = "The Barn"
    var version = 1
    var holeName = "The Orchard"
    var par = 4
    var poleHeightM = Settings.defaultPoleHeight
    var leanDeg = 0.0
    var inRadiusM = Flag.defaultInRadiusM
    var flag: Fix?
    var firingPoint: Fix?
    var boundary: [Fix] = []
    /// Optional so drafts saved before layups existed still decode; use `layups`.
    var layupPoints: [LayupPoint]?

    /// A marker pole partway down a long hole, with its height.
    struct LayupPoint: Codable, Equatable {
        var fix: Fix
        var poleHeightM: Double
    }

    /// In playing order: firing point → layup 1 → … → flag.
    var layups: [LayupPoint] {
        get { layupPoints ?? [] }
        set { layupPoints = newValue.isEmpty ? nil : newValue }
    }

    /// Adds a layup where it fits the path best (the least detour), so they stay in playing order
    /// whichever order they were walked in. Appended if the firing point or flag isn't recorded yet.
    mutating func insertLayup(_ point: LayupPoint) {
        guard let firingPoint, let flag else { layups.append(point); return }
        let path = [firingPoint.point] + layups.map(\.fix.point) + [flag.point]
        let p = point.fix.point
        let best = (0..<(path.count - 1)).min { a, b in
            func detour(_ k: Int) -> Double { Geo.distance(path[k], p) + Geo.distance(p, path[k + 1]) - Geo.distance(path[k], path[k + 1]) }
            return detour(a) < detour(b)
        } ?? layups.count
        layups.insert(point, at: best)
    }

    /// Each leg: from the firing point or a layup to the next target, with its ground distance.
    struct Leg: Equatable {
        var from: String
        var to: String
        var distance: Double
        var start: GeoPoint
        var end: GeoPoint
    }

    var legs: [Leg] {
        guard let firingPoint, let flag else { return [] }
        let stops = [("the firing point", firingPoint.point)]
            + layups.enumerated().map { ("layup \($0.offset + 1)", $0.element.fix.point) }
            + [("the flag", flag.point)]
        return zip(stops, stops.dropFirst()).map { a, b in
            Leg(from: a.0, to: b.0, distance: Geo.distance(a.1, b.1), start: a.1, end: b.1)
        }
    }

    var course: Course? {
        guard let flag, let firingPoint else { return nil }
        let hole = Hole(number: 1, name: holeName, par: par, firingPoints: [firingPoint.point],
                        layups: layups.map { Layup(position: $0.fix.point, poleHeightM: $0.poleHeightM) },
                        flag: Flag(position: flag.point, poleHeightM: poleHeightM, leanDeg: leanDeg, inRadiusM: inRadiusM))
        return Course(format: 1, id: CourseWriter.clean(name), name: name, version: version,
                      boundary: GeoPolygon(boundary.map(\.point)), holes: [hole])
    }

    var text: String? {
        course.map { CourseWriter.text(for: $0, comment: "Surveyed with the SpudGunGolf app. Keep this file out of public repositories.") }
    }

    static let key = "courseSurveyDraft"
}

/// Averages GPS fixes for a few seconds, keeping only good ones, for one surveyed point.
@MainActor
final class SurveySampler: NSObject, ObservableObject, CLLocationManagerDelegate {
    /// How long one point is averaged. The course format suggests about 60 s for the best result.
    static let seconds = 20.0
    /// Fixes worse than this are ignored.
    static let worstAccuracy = 15.0

    @Published private(set) var isSampling = false
    @Published private(set) var progress = 0.0
    @Published private(set) var latest: CLLocation?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()
    private var fixes: [CLLocation] = []
    private var started: Date?
    private var completion: ((CourseSurvey.Fix?) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    func sample(_ done: @escaping (CourseSurvey.Fix?) -> Void) {
        fixes = []
        started = Date()
        progress = 0
        isSampling = true
        completion = done
    }

    func cancel() {
        isSampling = false
        completion = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in self.add(locations) }
    }

    private func add(_ locations: [CLLocation]) {
        guard let last = locations.last else { return }
        latest = last
        guard isSampling, let started else { return }
        fixes += locations.filter { $0.horizontalAccuracy > 0 && $0.horizontalAccuracy <= Self.worstAccuracy }
        progress = min(1, Date().timeIntervalSince(started) / Self.seconds)
        guard progress >= 1 else { return }
        isSampling = false
        let done = completion
        completion = nil
        guard !fixes.isEmpty else { done?(nil); return }
        // Weight each fix by 1/accuracy², so the good ones count most.
        let w = fixes.map { 1 / ($0.horizontalAccuracy * $0.horizontalAccuracy) }
        let total = w.reduce(0, +)
        let lat = zip(fixes, w).reduce(0) { $0 + $1.0.coordinate.latitude * $1.1 } / total
        let lon = zip(fixes, w).reduce(0) { $0 + $1.0.coordinate.longitude * $1.1 } / total
        let accuracy = (1 / total).squareRoot()
        done?(CourseSurvey.Fix(point: GeoPoint(latitude: lat, longitude: lon), accuracy: accuracy, samples: fixes.count))
    }
}

/// Field → Survey a course: walk the property and record the pole's base, the firing point and the
/// boundary corners with averaged GPS. The result is checked by `CourseValidator` as you go, can be
/// loaded as this device's course, and can be shared as a course file for `courses/local/course.yaml`.
struct CourseSurveyView: View {
    @EnvironmentObject private var store: CourseStore
    @EnvironmentObject private var membership: SquadMembership
    @AppStorage(Settings.playerNameKey) private var player = Settings.defaultPlayerName
    @State private var sentToLeader: UUID?
    @StateObject private var sampler = SurveySampler()
    @AppStorage(CourseSurvey.key) private var draftData = Data()
    @State private var survey = CourseSurvey()
    @State private var recording: String?
    @State private var message: String?

    var body: some View {
        Form {
            Section {
                TextField("Course name", text: $survey.name)
                Stepper("Version \(survey.version)", value: $survey.version, in: 1...999)
                TextField("Hole name", text: $survey.holeName)
                Stepper("Par \(survey.par)", value: $survey.par, in: 1...12)
            } header: {
                Text("Course")
            } footer: {
                Text("Bump the version whenever anything moves.")
            }

            Section {
                Picker("Pole height", selection: $survey.poleHeightM) {
                    Text("8 ft (2.438 m)").tag(2.438)
                    Text("10 ft (3.048 m)").tag(3.048)
                    Text("12 ft (3.658 m)").tag(3.658)
                }
                Stepper(String(format: "Lean %.1f°", survey.leanDeg), value: $survey.leanDeg, in: 0...0.4, step: 0.1)
                Stepper(String(format: "Ring %.1f m", survey.inRadiusM), value: $survey.inRadiusM, in: 0.5...5, step: 0.5)
            } header: {
                Text("Flag")
            } footer: {
                Text("Enter the lean the lean check measured (under 0.5°).")
            }

            Section {
                pointRow("Pole base", systemImage: "flag", fix: survey.flag, id: "flag") { survey.flag = $0 }
                pointRow("Firing point", systemImage: "scope", fix: survey.firingPoint, id: "fp") { survey.firingPoint = $0 }
                if survey.layups.isEmpty, let leg = survey.legs.first {
                    LabeledContent("Firing distance", value: String(format: "%.1f m", leg.distance))
                }
            } header: {
                Text("Hole 1")
            } footer: {
                Text("Stand on the spot and tap Record. Each point averages GPS for \(Int(SurveySampler.seconds)) seconds; keep still.")
            }

            layupSection

            Section {
                ForEach(Array(survey.boundary.enumerated()), id: \.offset) { i, fix in
                    LabeledContent("Corner \(i + 1)", value: describe(fix))
                }
                .onDelete { survey.boundary.remove(atOffsets: $0) }
                Button {
                    record("corner") { if let f = $0 { survey.boundary.append(f) } }
                } label: {
                    Label(recording == "corner" ? "Recording…" : "Add a corner here", systemImage: "plus.circle")
                }
                .disabled(recording != nil)
            } header: {
                Text("Boundary")
            } footer: {
                Text("Walk the property line and add each corner in order. Include neighbouring land only with its owner's agreement. The safety fan (105 yd, ±30° of the line to the hole) must stay inside it.")
            }

            if recording != nil {
                Section {
                    ProgressView(value: sampler.progress) { Text("Averaging GPS…") }
                    Button("Cancel", role: .cancel) { sampler.cancel(); recording = nil }
                }
            }

            Section {
                if let latest = sampler.latest {
                    LabeledContent("GPS now", value: String(format: "±%.0f m", latest.horizontalAccuracy))
                } else if sampler.authorization == .denied || sampler.authorization == .restricted {
                    Text("Location is off for SpudGunGolf. Turn it on in Settings to survey.").foregroundStyle(.red)
                } else {
                    Text("Waiting for GPS…").foregroundStyle(.secondary)
                }
            }

            checkSection

            Section {
                Button {
                    if let text = survey.text {
                        store.loadSurveyed(text)
                        message = isPracticeOnly ? "Loaded as this device's course, for practice only." : "Loaded as this device's course."
                    }
                } label: {
                    Label(isPracticeOnly ? "Use this course for practice on this device" : "Use this course on this device",
                          systemImage: "checkmark.circle")
                }
                .disabled(!isValid && !isPracticeOnly)
                if let text = survey.text {
                    ShareLink(item: text, preview: SharePreview("\(survey.name) course file")) {
                        Label("Share course file", systemImage: "square.and.arrow.up")
                    }
                    if let course = survey.course {
                        NavigationLink {
                            TheaterSendView(title: "Send to Theater",
                                            summary: ["\(course.name) · \(course.holes.count) hole\(course.holes.count == 1 ? "" : "s")"],
                                            payloads: { [.field(FieldSubmission(author: player, time: Date(), course: course, yaml: text))] })
                        } label: {
                            Label("Send to Theater", systemImage: "theatermasks")
                        }
                        if membership.isInSquad {
                            Button {
                                sentToLeader = membership.sendField(FieldSubmission(author: player, time: Date(), course: course, yaml: text))
                                if sentToLeader == nil { message = "Not linked to the squad's iPad right now. Try again in a moment." }
                            } label: {
                                Label("Send to my squad leader", systemImage: "person.badge.shield.checkmark")
                            }
                            .disabled(!membership.canSendToLeader || (!isValid && !isPracticeOnly))
                            if let why = leaderBlocker {
                                Text(why).font(.footnote).foregroundStyle(.orange)
                            }
                            if let id = sentToLeader, let s = membership.sentToLeader.first(where: { $0.id == id }) {
                                SentItemRow(title: s.title, receipt: s.receipt)
                            }
                        }
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            } footer: {
                Text("To make it every build's default, save the shared file on your Mac as courses/local/course.yaml. Git ignores that folder, so your coordinates stay out of the public repo.")
            }

            Section {
                Button("Start over", role: .destructive) { survey = CourseSurvey() }
            }
        }
        .navigationTitle("Survey a course")
        .onAppear {
            if let saved = try? JSONDecoder().decode(CourseSurvey.self, from: draftData) { survey = saved }
            sampler.start()
        }
        .onDisappear { sampler.stop() }
        .onChange(of: survey) { _, new in draftData = (try? JSONEncoder().encode(new)) ?? Data() }
    }

    // MARK: Checking

    private var problems: [CourseProblem] {
        guard let text = survey.text else { return [] }
        return CourseFile.load(text).problems
    }

    /// Why Send to my squad leader is greyed out, said under it rather than left silent.
    private var leaderBlocker: String? {
        if !isValid && !isPracticeOnly { return "Fix the course's problems above first." }
        guard !membership.canSendToLeader else { return nil }
        switch membership.state {
        case .reconnecting: return "Reconnecting to \(membership.squadName ?? "the squad")'s iPad… Tap again once it's back."
        case .connecting: return "Joining \(membership.squadName ?? "the squad")…"
        default: return "Not linked to the squad's iPad. Open Play → Join squad to rejoin."
        }
    }

    private var isValid: Bool { survey.text != nil && !problems.contains { $0.severity == .error } }
    /// Only the safety fan fails: fine for practice and demos, not for real rounds.
    private var isPracticeOnly: Bool {
        survey.text != nil && !isValid && CourseValidator.practiceAllows(problems)
    }

    @ViewBuilder private var checkSection: some View {
        Section {
            if survey.course == nil {
                Text("Record the pole base and the firing point to check the course.").foregroundStyle(.secondary)
            } else if problems.isEmpty {
                Label("Passes every check", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                if isPracticeOnly {
                    Label("Practice only: everything passes except the safety fan or a shot past 100 yd, so real rounds stay off. Practice and demos work. To play for real, keep every leg within 91 m: move the firing point closer, or add layup points.",
                          systemImage: "gamecontroller").foregroundStyle(.orange).font(.footnote)
                }
                ForEach(layupHints, id: \.self) { hint in
                    Label(hint, systemImage: "mappin.and.ellipse")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.blue)
                        .padding(.vertical, 4)
                }
                ForEach(problems, id: \.self) { p in
                    Label(p.message, systemImage: p.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(p.severity == .error ? .red : .orange)
                        .font(.footnote)
                }
            }
        } header: {
            Text("Check")
        }
    }

    // MARK: Layups

    @ViewBuilder private var layupSection: some View {
        Section {
            ForEach(Array(survey.layups.enumerated()), id: \.offset) { i, layup in
                HStack {
                    Label("Layup \(i + 1)", systemImage: "mappin.and.ellipse")
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Menu {
                            ForEach(Self.poleHeights, id: \.m) { h in
                                Button(h.title) { survey.layups[i].poleHeightM = h.m }
                            }
                        } label: {
                            Text(Self.poleTitle(layup.poleHeightM)).font(.footnote)
                        }
                        Text(describe(layup.fix)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { survey.layups.remove(atOffsets: $0) }
            Button {
                let height = survey.poleHeightM
                record("layup") { if let f = $0 { survey.insertLayup(.init(fix: f, poleHeightM: height)) } }
            } label: {
                Label(recording == "layup" ? "Recording…" : "Add a layup point here", systemImage: "plus.circle")
            }
            .disabled(recording != nil)
            if survey.legs.count > 1 {
                ForEach(Array(survey.legs.enumerated()), id: \.offset) { i, leg in
                    LabeledContent("Leg \(i + 1): \(leg.from) → \(leg.to)") {
                        Text(String(format: "%.1f m", leg.distance))
                            .foregroundStyle(leg.distance > Safety.limits.maxSolutionRange ? .red : .secondary)
                    }
                    .font(.footnote)
                }
            }
        } header: {
            Text("Layup points")
        } footer: {
            Text("For a hole longer than one shot (91 m, 100 yd): stand a marker pole partway and record its base. Each leg is one shot. Layups go in playing order by where they are, whichever order you walk them. Swipe to delete.")
        }
    }

    private static let poleHeights: [(title: String, m: Double)] = [
        ("8 ft (2.438 m)", 2.438), ("10 ft (3.048 m)", 3.048), ("12 ft (3.658 m)", 3.658),
    ]

    private static func poleTitle(_ m: Double) -> String {
        poleHeights.first { abs($0.m - m) < 0.001 }?.title ?? String(format: "%.3f m pole", m)
    }

    /// For each leg past one shot: where to put layup points to fix it, and how far.
    private var layupHints: [String] {
        let limit = Safety.limits.maxSolutionRange
        return survey.legs.compactMap { leg in
            guard leg.distance > limit else { return nil }
            let extra = Int((leg.distance / limit).rounded(.up)) - 1
            let step = leg.distance / Double(extra + 1)
            let over = String(format: "From %@ to %@ is %.0f m, past the %.0f m (100 yd) one shot can go.",
                              leg.from, leg.to, leg.distance, limit)
            if extra == 1 {
                return over + String(format: " Walk about %.0f m from %@ toward %@ (about halfway), stand a marker pole there and tap Add a layup point here.",
                                     step, leg.from, leg.to)
            }
            return over + String(format: " Add %d layup points about %.0f m apart: the first about %.0f m from %@ toward %@.",
                                 extra, step, step, leg.from, leg.to)
        }
    }

    // MARK: Rows

    private func pointRow(_ title: String, systemImage: String, fix: CourseSurvey.Fix?, id: String,
                          set: @escaping (CourseSurvey.Fix) -> Void) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            if let fix { Text(describe(fix)).font(.footnote).foregroundStyle(.secondary) }
            Button(recording == id ? "Recording…" : (fix == nil ? "Record" : "Redo")) {
                record(id) { if let f = $0 { set(f) } }
            }
            .buttonStyle(.bordered)
            .disabled(recording != nil)
        }
    }

    private func record(_ id: String, _ done: @escaping (CourseSurvey.Fix?) -> Void) {
        recording = id
        message = nil
        sampler.sample { fix in
            recording = nil
            if fix == nil { message = "No GPS fix better than ±\(Int(SurveySampler.worstAccuracy)) m. Try again in the open." }
            done(fix)
        }
    }

    private func describe(_ fix: CourseSurvey.Fix) -> String {
        String(format: "±%.1f m · %d fixes", fix.accuracy, fix.samples)
    }
}
