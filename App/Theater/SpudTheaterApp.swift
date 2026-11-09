import SwiftUI
import MapKit
import CoreGeo
import SafetyKit
import CourseKit
import GroupKit
import GroupLink
import FieldKit
import UniformTypeIdentifiers

/// v4 Theater Mode: find the squads' iPads on the network and watch them as an observer. Each
/// squad sends its course, and its members' GPS positions as they come in. The site map shows the
/// course on satellite imagery with every member on it; the 3D view (Field3DView.swift) shows it on
/// the ground's real shape. Watching only: no firing data reaches it.
@main
struct SpudTheaterApp: App {
    @StateObject private var model = TheaterModel()

    var body: some Scene {
        WindowGroup("SpudGunGolf Theater") {
            TheaterView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 640)
                .onAppear { model.start() }
        }
    }
}

/// One squad being watched.
struct Watch: Identifiable {
    var id: String { name }
    var name: String
    var link: GroupClient.Status = .searching
    var squad: Squad?
    var course: Course?
    var status: SquadStatus?
    var positions: [MemberID: MemberPosition] = [:]
    /// The squad leader's orders, as an observer sees them, oldest first (the last 20).
    var orders: [Order] = []
    let client: GroupClient
}

@MainActor
final class TheaterModel: ObservableObject {
    @Published var found: [GroupBrowser.Found] = []
    @Published var watches: [String: Watch] = [:]
    @Published var browserProblem: String?
    /// Every field this host knows (FieldKit's registry), whether or not anyone is playing it.
    @Published private(set) var fields: [(field: RegisteredField, course: Course)] = []
    @Published var notice: String?
    let store = FieldStore(root: FieldStore.defaultRoot)
    private let browser = GroupBrowser(queue: .main)
    private let device: UUID = {
        let key = "theaterDevice"
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return u
    }()

    func start() {
        reloadFields()
        browser.onChange = { [weak self] f in MainActor.assumeIsolated { self?.found = f } }
        browser.onFailed = { [weak self] e in MainActor.assumeIsolated { self?.browserProblem = e } }
        browser.start()
    }

    /// Watches a squad by its Bonjour name. The link rejoins on its own if the iPad sleeps.
    func watch(_ name: String, code: String) {
        stop(name)
        let code = JoinCode.normalized(code)
        let hello = Hello(name: Host.current().localizedName ?? "Theater", device: device, joinCode: code, role: .observer)
        let client = GroupClient(squadName: name, joinCode: code, hello: hello, queue: .main)
        watches[name] = Watch(name: name, client: client)
        client.onStatus = { [weak self] s in MainActor.assumeIsolated { self?.watches[name]?.link = s } }
        client.onMessage = { [weak self] m in MainActor.assumeIsolated { self?.receive(m, from: name) } }
        client.start()
    }

    func stop(_ name: String) {
        watches[name]?.client.stop()
        watches[name] = nil
    }

    func retryAll() {
        for w in watches.values { w.client.retryNow() }
    }

    // MARK: Fields

    func reloadFields() { fields = store.fields() }

    /// Squads being watched on a field.
    func watches(on courseID: String) -> [Watch] {
        watches.values.filter { $0.course?.id == courseID }.sorted { $0.name < $1.name }
    }

    /// Imports a course file (course.yaml) as a field, after CourseKit's checks.
    func importCourse(from url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            notice = "Couldn't read \(url.lastPathComponent)."
            return
        }
        let result = CourseFile.load(text)
        guard let course = result.course else {
            notice = "\(url.lastPathComponent) isn't a usable course: " + result.problems.map(\.description).prefix(3).joined(separator: " ")
            return
        }
        register(course, source: "Imported from \(url.lastPathComponent)", yaml: text)
    }

    func forget(_ courseID: String) {
        do {
            let dest = try store.forget(courseID)
            notice = "Forgot the field. Its folder was moved to \(dest.path)."
        } catch {
            notice = "Couldn't forget it: \(error.localizedDescription)"
        }
        reloadFields()
    }

    private func register(_ course: Course, source: String, yaml: String? = nil) {
        do {
            switch try store.register(course, source: source, yaml: yaml) {
            case .added: notice = "Added \(course.name) to the fields."
            case let .updated(from): notice = "Updated \(course.name) from v\(from) to v\(course.version)."
            case .unchanged: break
            case let .olderIgnored(v): notice = "\(course.name) v\(course.version) is older than the v\(v) already saved; kept v\(v)."
            }
        } catch {
            notice = "Couldn't save \(course.name): \(error.localizedDescription)"
        }
        reloadFields()
    }

    private func receive(_ m: GroupMessage, from name: String) {
        switch m.body {
        case let .observing(squad): watches[name]?.squad = squad
        case let .course(course):
            watches[name]?.course = course
            // Every course a squad plays becomes a field on this host.
            register(course, source: "From squad \(name)")
            store.markSeen(course.id)
        case let .squadStatus(s): watches[name]?.status = s; watches[name]?.squad = s.squad
        case let .positions(_, list):
            for p in list { if let id = p.member { watches[name]?.positions[id] = p } }
        case let .order(o):
            guard var w = watches[name], !w.orders.contains(where: { $0.id == o.id }) else { break }
            w.orders.append(o)
            if w.orders.count > 20 { w.orders.removeFirst(w.orders.count - 20) }
            watches[name] = w
        default: break   // an observer is sent nothing else
        }
    }
}

// MARK: Views

struct TheaterView: View {
    @EnvironmentObject private var model: TheaterModel
    @State private var codes: [String: String] = [:]
    @AppStorage("mapMode") private var mapMode: MapMode = .map
    @AppStorage("selectedField") private var selectedField: String = ""
    @State private var importing = false
    @State private var forgetting: RegisteredField?

    enum MapMode: String { case map, threeD }

    /// The field shown: the one picked, or the first registered.
    private var shownField: (field: RegisteredField, course: Course)? {
        model.fields.first { $0.field.id == selectedField } ?? model.fields.first
    }

    /// What the map and 3D view draw: the shown field (with no members of its own) and the
    /// squads playing on it. With no fields yet, every watched squad.
    private var siteMapSquads: [SiteMapSquad] {
        guard let f = shownField else {
            return model.watches.values.sorted { $0.name < $1.name }.map(\.siteMapSquad)
        }
        let fieldItself = SiteMapSquad(id: "field:" + f.field.id, course: f.course, members: [], positions: [:],
                                       activeHole: nil, walkingOut: true)
        return [fieldItself] + model.watches(on: f.field.id).map(\.siteMapSquad)
    }

    private var shownWatches: [Watch] {
        guard let f = shownField else { return model.watches.values.sorted { $0.name < $1.name } }
        return model.watches(on: f.field.id)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { shownField?.field.id }, set: { selectedField = $0 ?? "" })) {
                Section {
                    if model.fields.isEmpty {
                        Text("No fields yet. Import a course file with +, or watch a squad: the course it plays is saved here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.fields, id: \.field.id) { entry in
                        FieldRow(field: entry.field, live: model.watches(on: entry.field.id).count)
                            .tag(entry.field.id)
                            .contextMenu {
                                Button("Show in Finder") {
                                    NSWorkspace.shared.activateFileViewerSelecting([model.store.courseDirectory(entry.field.id)])
                                }
                                Divider()
                                Button("Forget field…", role: .destructive) { forgetting = entry.field }
                            }
                    }
                } header: {
                    HStack {
                        Text("Fields")
                        Spacer()
                        Button { importing = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.borderless)
                            .help("Import a course file (course.yaml)")
                    }
                }

                Section("Squads on this network") {
                    if model.found.isEmpty {
                        Text("Looking for squads… A commander's iPad shows up here once it opens a squad.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.found) { f in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(f.name).font(.headline)
                                if !f.isCompatible {
                                    Text("v\(f.protocolVersion.map(String.init) ?? "?"), update").foregroundStyle(.orange).font(.caption)
                                }
                                if let c = model.watches[f.name]?.course {
                                    Spacer()
                                    Button(c.name) { selectedField = c.id }
                                        .buttonStyle(.link).font(.caption)
                                        .help("Show the field this squad is playing")
                                }
                            }
                            HStack {
                                TextField("Join code", text: Binding(get: { codes[f.name, default: ""] },
                                                                     set: { codes[f.name] = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 110)
                                    .onSubmit { startWatching(f) }
                                if model.watches[f.name] == nil {
                                    Button("Watch") { startWatching(f) }
                                        .disabled(JoinCode.normalized(codes[f.name, default: ""]).count != 6 || !f.isCompatible)
                                } else {
                                    Button("Stop") { model.stop(f.name) }
                                }
                            }
                        }
                        .padding(.vertical, 2)
                        .selectionDisabled()
                    }
                }
                if let p = model.browserProblem { Text(p).foregroundStyle(.red).selectionDisabled() }
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 290)
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [UTType(filenameExtension: "yaml") ?? .plainText,
                                                UTType(filenameExtension: "yml") ?? .plainText, .plainText],
                          allowsMultipleSelection: true) { result in
                if case let .success(urls) = result { for u in urls { model.importCourse(from: u) } }
            }
            .confirmationDialog("Forget \(forgetting?.name ?? "this field")?", isPresented: Binding(
                get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }), titleVisibility: .visible) {
                Button("Forget field", role: .destructive) {
                    if let f = forgetting { model.forget(f.id) }
                    forgetting = nil
                }
            } message: {
                Text("It leaves the list. Its folder (course, elevation, meshes, captures) is moved aside, not deleted. Watching a squad on it adds it again.")
            }
        } detail: {
            VSplitView {
                Group {
                    if siteMapSquads.isEmpty {
                        ContentUnavailableView("No field to show", systemImage: "map",
                                               description: Text("Import a course file with + under Fields, or watch a squad."))
                    } else {
                        switch mapMode {
                        case .map: SiteMap(squads: siteMapSquads)
                        case .threeD: Field3DView(squads: siteMapSquads)
                        }
                    }
                }
                .frame(minHeight: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let f = shownField { FieldHeader(field: f.field, course: f.course) }
                        if let n = model.notice {
                            HStack {
                                Text(n).font(.callout)
                                Spacer()
                                Button("OK") { model.notice = nil }.buttonStyle(.borderless)
                            }
                            .padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                        }
                        if shownWatches.isEmpty {
                            Text(shownField == nil ? "Not watching a squad. Enter a squad's join code and press Watch."
                                                   : "No squad is playing this field right now.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(shownWatches) { SquadCard(watch: $0) }
                        let elsewhere = model.watches.count - shownWatches.count
                        if shownField != nil, elsewhere > 0 {
                            Text("\(elsewhere) more squad\(elsewhere == 1 ? "" : "s") watched on other fields.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                }
                .frame(minHeight: 160)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $mapMode) {
                        Label("Map", systemImage: "map").tag(MapMode.map)
                        Label("3D", systemImage: "mountain.2").tag(MapMode.threeD)
                    }
                    .pickerStyle(.segmented)
                    .help("The site map, or the course in 3D on the ground's real shape")
                }
            }
        }
    }

    private func startWatching(_ f: GroupBrowser.Found) {
        guard JoinCode.normalized(codes[f.name, default: ""]).count == 6, f.isCompatible else { return }
        model.watch(f.name, code: codes[f.name, default: ""])
    }
}

/// A field in the sidebar.
struct FieldRow: View {
    let field: RegisteredField
    let live: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(field.name).font(.headline)
                if live > 0 {
                    Text("\(live) live").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.green.opacity(0.25), in: Capsule())
                }
            }
            Text("\(field.holes) hole\(field.holes == 1 ? "" : "s") · par \(field.totalPar) · v\(field.version)")
                .font(.caption).foregroundStyle(.secondary)
            Text(field.lastSeen.map { "Played " + $0.formatted(.relative(presentation: .named)) } ?? field.source)
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// The selected field's details over the squads list.
struct FieldHeader: View {
    let field: RegisteredField
    let course: Course

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(field.name).font(.title2.weight(.semibold))
            Text("\(course.id) · v\(field.version) · \(field.holes) holes, par \(field.totalPar) · \(field.source)")
                .font(.caption).foregroundStyle(.secondary)
            Text("Added \(field.registeredAt.formatted(date: .abbreviated, time: .shortened))"
                 + (field.lastSeen.map { " · last played \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension Watch {
    /// What the shared site map (App/Shared/SiteMap.swift) draws for this squad.
    var siteMapSquad: SiteMapSquad {
        SiteMapSquad(id: name, course: course, members: squad?.members ?? [], positions: positions,
                     activeHole: status?.hole, walkingOut: status?.walkingOut ?? true, orders: orders)
    }
}

struct SquadCard: View {
    let watch: Watch

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if let s = watch.status {
                    Text(phaseLine(s)).font(.subheadline)
                    if !s.holds.isEmpty {
                        Text("Holds: " + s.holds.map(\.description).joined(separator: " "))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                if let c = watch.course {
                    Text("\(c.name) v\(c.version) · \(c.holes.count) holes, par \(c.totalPar)").font(.caption).foregroundStyle(.secondary)
                }
                if !watch.orders.isEmpty {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Latest orders").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(watch.orders.suffix(4).reversed()) { o in
                            HStack(spacing: 6) {
                                Image(systemName: o.kind.systemImage).frame(width: 16)
                                Text(o.kind.title).fontWeight(.semibold)
                                Text("to " + recipients(o))
                                if !o.text.isEmpty { Text("· " + o.text).lineLimit(1) }
                                Spacer()
                                TimelineView(.periodic(from: .now, by: 10)) { t in
                                    Text(age(o.time, now: t.date)).foregroundStyle(.secondary)
                                }
                            }
                            .font(.caption)
                        }
                    }
                }
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Member"); Text("Role"); Text("GPS"); Text("±"); Text("Seen")
                    }
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(watch.squad?.members ?? []) { m in
                        let p = watch.positions[m.id]
                        GridRow {
                            Text(m.name)
                            Text(m.role.rawValue)
                            Text(p.map { String(format: "%.6f, %.6f", $0.at.latitude, $0.at.longitude) } ?? "–").monospacedDigit()
                            Text(p.map { String(format: "%.0f m", $0.accuracy) } ?? "–").monospacedDigit()
                            TimelineView(.periodic(from: .now, by: 1)) { t in
                                Text(p.map { age($0.time, now: t.date) } ?? "never")
                                    .foregroundStyle(p.map { t.date.timeIntervalSince($0.time) > 15 } ?? true ? .orange : .primary)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(watch.squad?.name ?? watch.name).font(.title3.weight(.semibold))
                Spacer()
                Text(linkText).font(.caption).foregroundStyle(linkColor)
            }
        }
    }

    private func recipients(_ o: Order) -> String {
        guard let to = o.to else { return "the team" }
        let names = (watch.squad?.members ?? []).filter { to.contains($0.id) }.map(\.name)
        return names.isEmpty ? "\(to.count) member(s)" : names.joined(separator: ", ")
    }

    private var linkText: String {
        switch watch.link {
        case .searching: return "Looking for the squad…"
        case .connecting: return "Connecting…"
        case .connected: return "Watching"
        case let .reconnecting(why): return "Reconnecting… (\(why))"
        case let .stopped(why): return why
        }
    }

    private var linkColor: Color {
        switch watch.link {
        case .connected: return .green
        case .stopped: return .red
        case .reconnecting: return .orange
        default: return .secondary
        }
    }

    private func phaseLine(_ s: SquadStatus) -> String {
        var parts: [String] = []
        if let h = s.hole { parts.append("Hole \(h)") } else { parts.append("Between holes") }
        if let p = s.phase { parts.append(p.rawValue) }
        if s.walkingOut { parts.append("walking out") }
        parts.append("\(s.rounds.count) rounds")
        parts.append(String(format: "total %.1f (%+.1f)", s.total, s.toPar))
        return parts.joined(separator: " · ")
    }

    private func age(_ d: Date, now: Date) -> String {
        let s = Int(now.timeIntervalSince(d))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}
