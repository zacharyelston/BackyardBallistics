import SwiftUI
import CoreGeo
import GroupKit
import GroupLink

/// v4 Theater Mode, first slice: find the squads' iPads on the network and watch them as an
/// observer. Shows each squad's members, their live positions and the squad's phase and holds.
/// The course map (T2) builds on this.
@main
struct SpudTheaterApp: App {
    @StateObject private var model = TheaterModel()

    var body: some Scene {
        WindowGroup("SpudGunGolf Theater") {
            TheaterView()
                .environmentObject(model)
                .frame(minWidth: 820, minHeight: 520)
                .onAppear { model.start() }
        }
    }
}

/// One squad being watched.
struct Watch: Identifiable {
    var id: String { name }
    var name: String
    var state: GroupConnection.State = .connecting
    var squad: Squad?
    var status: SquadStatus?
    var positions: [MemberID: MemberPosition] = [:]
    var problem: String?
    let connection: GroupConnection
}

@MainActor
final class TheaterModel: ObservableObject {
    @Published var found: [GroupBrowser.Found] = []
    @Published var watches: [String: Watch] = [:]
    @Published var browserProblem: String?
    private let browser = GroupBrowser(queue: .main)
    private let device = UUID()

    func start() {
        browser.onChange = { [weak self] f in MainActor.assumeIsolated { self?.found = f } }
        browser.onFailed = { [weak self] e in MainActor.assumeIsolated { self?.browserProblem = e } }
        browser.start()
    }

    func watch(_ f: GroupBrowser.Found, code: String) {
        stop(f.name)
        let c = GroupConnection(to: f.endpoint, joinCode: code, queue: .main)
        let name = f.name
        watches[name] = Watch(name: name, connection: c)
        c.onState = { [weak self] s in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.watches[name]?.state = s
                if s == .ready {
                    c.send(.hello(Hello(name: Host.current().localizedName ?? "Theater", device: self.device,
                                        joinCode: JoinCode.normalized(code), role: .observer)))
                }
                if case let .failed(why) = s { self.watches[name]?.problem = why }
            }
        }
        c.onMessage = { [weak self] m in
            MainActor.assumeIsolated { self?.receive(m, from: name) }
        }
        c.start()
    }

    func stop(_ name: String) {
        watches[name]?.connection.send(.bye)
        watches[name]?.connection.cancel()
        watches[name] = nil
    }

    private func receive(_ m: GroupMessage, from name: String) {
        switch m.body {
        case let .observing(squad): watches[name]?.squad = squad
        case let .squadStatus(s): watches[name]?.status = s; watches[name]?.squad = s.squad
        case let .positions(_, list):
            for p in list { if let id = p.member { watches[name]?.positions[id] = p } }
        case let .refused(why): watches[name]?.problem = why
        default: break   // an observer is sent nothing else
        }
    }
}

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
                                    Text("v\(f.protocolVersion.map(String.init) ?? "?")").foregroundStyle(.orange)
                                }
                            }
                            HStack {
                                TextField("Join code", text: Binding(get: { codes[f.name, default: ""] },
                                                                     set: { codes[f.name] = $0 }))
                                    .textFieldStyle(.roundedBorder).frame(width: 110)
                                if model.watches[f.name] == nil {
                                    Button("Watch") { model.watch(f, code: codes[f.name, default: ""]) }
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
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if model.watches.isEmpty {
                        ContentUnavailableView("Not watching a squad", systemImage: "binoculars",
                                               description: Text("Enter a squad's join code and press Watch."))
                    }
                    ForEach(model.watches.values.sorted { $0.name < $1.name }) { w in
                        SquadCard(watch: w)
                    }
                }
                .padding()
            }
        }
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
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    GridRow {
                        Text("Member"); Text("Role"); Text("Position"); Text("±"); Text("Seen")
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
                if let problem = watch.problem { Text(problem).foregroundStyle(.red).font(.caption) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text(watch.squad?.name ?? watch.name).font(.title3.weight(.semibold))
                Spacer()
                Text(stateText).font(.caption).foregroundStyle(watch.state == .ready ? .green : .secondary)
            }
        }
    }

    private var stateText: String {
        switch watch.state {
        case .connecting: return "Connecting…"
        case .ready: return "Watching"
        case .failed: return "Not connected"
        case .closed: return "Closed"
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
