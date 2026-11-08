import SwiftUI
import MapKit
import CoreGeo
import SafetyKit
import CourseKit
import GroupKit
import GroupLink

/// v4 Theater Mode: find the squads' iPads on the network and watch them as an observer. Each
/// squad sends its course, and its members' GPS positions as they come in. The site map shows the
/// course on satellite imagery with every member on it. Watching only: no firing data reaches it.
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
        default: break   // an observer is sent nothing else
        }
    }
}

// MARK: Views

struct TheaterView: View {
    @EnvironmentObject private var model: TheaterModel
    @State private var codes: [String: String] = [:]

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
                SiteMap(squads: model.watches.values.sorted { $0.name < $1.name }.map(\.siteMapSquad))
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
                     activeHole: status?.hole, walkingOut: status?.walkingOut ?? true)
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
