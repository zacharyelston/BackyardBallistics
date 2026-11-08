import SwiftUI
import MapKit
import CoreGeo
import SafetyKit
import CourseKit
import GroupKit
import GroupLink

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
    private let browser = GroupBrowser(queue: .main)
    private let device: UUID = {
        let key = "theaterDevice"
        if let s = UserDefaults.standard.string(forKey: key), let u = UUID(uuidString: s) { return u }
        let u = UUID()
        UserDefaults.standard.set(u.uuidString, forKey: key)
        return u
    }()

    func start() {
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

    private func receive(_ m: GroupMessage, from name: String) {
        switch m.body {
        case let .observing(squad): watches[name]?.squad = squad
        case let .course(course): watches[name]?.course = course
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

    enum MapMode: String { case map, threeD }

    private var siteMapSquads: [SiteMapSquad] { model.watches.values.sorted { $0.name < $1.name }.map(\.siteMapSquad) }

    var body: some View {
        NavigationSplitView {
            List {
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
                    }
                }
                if let p = model.browserProblem { Text(p).foregroundStyle(.red) }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 280)
        } detail: {
            VSplitView {
                Group {
                    switch mapMode {
                    case .map: SiteMap(squads: siteMapSquads)
                    case .threeD: Field3DView(squads: siteMapSquads)
                    }
                }
                .frame(minHeight: 320)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if model.watches.isEmpty {
                            ContentUnavailableView("Not watching a squad", systemImage: "binoculars",
                                                   description: Text("Enter a squad's join code and press Watch."))
                        }
                        ForEach(model.watches.values.sorted { $0.name < $1.name }) { SquadCard(watch: $0) }
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
