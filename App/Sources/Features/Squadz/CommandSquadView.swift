import SwiftUI
import CourseKit
import GroupKit

/// Play → v3 Squadz → Command a squad: start a squad on the loaded course, show its join code and
/// QR code, and watch members join with live positions. Built for the iPad in landscape; works in
/// portrait and on a phone too.
struct CommandSquadView: View {
    @EnvironmentObject private var courses: CourseStore
    @EnvironmentObject private var command: SquadCommand
    @AppStorage("squadName") private var squadName = "Red"

    var body: some View {
        Group {
            if command.host == nil {
                setup
            } else if !command.isAdvertising, command.link == .off {
                resume
            } else {
                SquadLobbyView()
            }
        }
        .navigationTitle("Command a squad")
        // Keep the commander's iPad awake while this screen is open: if it sleeps, every phone drops.
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    // MARK: Setup

    private var setup: some View {
        Form {
            Section {
                TextField("Squad name", text: $squadName)
                    .textInputAutocapitalization(.words)
                if let course = courses.practiceCourse {
                    LabeledContent("Course", value: course.name)
                    LabeledContent("Mode", value: "Practice (simulated rounds)")
                } else {
                    Text("Load a course first (Play → Course).").foregroundStyle(.secondary)
                }
            } header: {
                Text("Squad")
            } footer: {
                Text("The squad is the player: its name goes on the scorecard. Members join from their phones with the code this iPad shows.")
            }
            Section {
                Button {
                    if let course = courses.practiceCourse { command.start(squadName: squadName, course: course) }
                } label: {
                    Label("Start the squad", systemImage: "person.3.fill")
                }
                .disabled(courses.practiceCourse == nil)
            }
        }
    }

    private var resume: some View {
        Form {
            if let host = command.host {
                Section {
                    LabeledContent("Squad", value: host.player)
                    LabeledContent("Course", value: host.round.course.name)
                    LabeledContent("Members", value: "\(host.round.squad.members.count)")
                    LabeledContent("Join code", value: SquadLobbyView.spaced(host.joinCode))
                } header: {
                    Text("Saved squad")
                } footer: {
                    Text("Resuming keeps the same code, so phones can rejoin as the same members.")
                }
                Section {
                    Button { command.advertise() } label: { Label("Resume \(host.player)", systemImage: "play.fill") }
                    Button(role: .destructive) { command.end() } label: { Label("End the squad", systemImage: "xmark.circle") }
                }
            }
        }
    }
}

/// The squad screen: the field map, with the code, QR code, roster and status beside it in
/// landscape (map in the main area) and below it in portrait.
struct SquadLobbyView: View {
    @EnvironmentObject private var command: SquadCommand
    @State private var confirmEnd = false

    var body: some View {
        GeometryReader { geo in
            if geo.size.width > geo.size.height && geo.size.width > 700 {
                HStack(spacing: 0) {
                    map
                    ScrollView {
                        VStack(spacing: 16) { codePanel(compact: true); SquadOrdersPanel(); rosterPanel; SquadHolePanel(); SquadLocksPanel(); SquadInboxPanel(); statusPanel }.padding(16)
                    }
                    .frame(width: min(400, geo.size.width * 0.36))
                    .background(Color(.systemGroupedBackground))
                }
            } else {
                ScrollView {
                    VStack(spacing: 20) {
                        map.frame(height: max(320, geo.size.height * 0.45))
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        codePanel(compact: false); SquadOrdersPanel(); rosterPanel; SquadHolePanel(); SquadLocksPanel(); SquadInboxPanel(); statusPanel
                    }
                    .padding()
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { command.stop() } label: { Label("Stop advertising", systemImage: "pause.circle") }
                    Button(role: .destructive) { confirmEnd = true } label: { Label("End the squad", systemImage: "xmark.circle") }
                } label: {
                    Label("Squad", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("End the squad?", isPresented: $confirmEnd, titleVisibility: .visible) {
            Button("End it", role: .destructive) { command.end() }
        } message: {
            Text("Members are disconnected and the code stops working. A new squad gets a new code.")
        }
    }

    // MARK: Panels

    /// The field: the squad's course, its members' positions and the hole in play.
    @ViewBuilder private var map: some View {
        if let host = command.host {
            SiteMap(squads: [SiteMapSquad(id: host.player, course: host.round.course,
                                          members: host.round.squad.members, positions: host.positions,
                                          activeHole: host.round.hole?.holeNumber, walkingOut: host.round.walkingOut,
                                          rays: host.locks.filter { $0.status == .used }.map {
                                              SiteMapRay(from: $0.report.lock.location, to: $0.report.lock.polePosition)
                                          },
                                          orders: Array(host.orders.suffix(20)),
                                          pointers: command.orderPointers,
                                          notes: Array(host.notes.suffix(30)))],
                    selected: command.orderTargets,
                    draftPlace: command.orderPlace,
                    onTapPlace: command.placingOrder ? { command.setPlace($0) } : nil,
                    onTapMember: command.placingOrder ? nil : { command.toggleTarget($0) })
                .overlay(alignment: .top) {
                    if command.placingOrder, let kind = command.orderKind {
                        Label("Tap where: \(kind.title)", systemImage: "hand.tap.fill")
                            .font(.headline).padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.orange, in: Capsule()).foregroundStyle(.white)
                            .padding(.top, 12)
                    }
                }
        }
    }

    private func codePanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 10 : 16) {
            if let host = command.host {
                Text(host.player).font(compact ? .title2.weight(.bold) : .title.weight(.bold))
                Text("Join code").font(.subheadline).foregroundStyle(.secondary)
                Text(Self.spaced(host.joinCode))
                    .font(.system(size: compact ? 34 : 44, weight: .heavy, design: .monospaced))
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .textSelection(.enabled)
                QRCodeView(text: host.joinCode)
                    .frame(maxWidth: compact ? 150 : 220, maxHeight: compact ? 150 : 220)
                    .padding(12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                linkLabel
                Text("\(host.round.course.name) · practice").font(.footnote).foregroundStyle(.secondary)
                Text("On each phone: Play → v3 Squadz → Join squad, pick \(host.player) and type the code.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder private var linkLabel: some View {
        switch command.link {
        case .off:
            Label("Not advertising", systemImage: "antenna.radiowaves.left.and.right.slash").foregroundStyle(.secondary)
        case .starting:
            Label("Starting…", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.secondary)
        case .listening:
            Label("Open for members", systemImage: "antenna.radiowaves.left.and.right").foregroundStyle(.green)
        case let .failed(error):
            VStack(spacing: 6) {
                Label("Couldn't open the squad: \(error)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Try again") { command.advertise() }
            }
            .font(.footnote)
        }
    }

    private var rosterPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Members").font(.headline)
                Spacer()
                if command.observerCount > 0 {
                    Label("\(command.observerCount) watching", systemImage: "eye").font(.footnote).foregroundStyle(.secondary)
                }
            }
            if command.roster.isEmpty {
                Text("No one yet. Members appear here as they join.").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    VStack(spacing: 0) {
                        ForEach(command.roster) { line in
                            row(line, now: context.date)
                            if line.id != command.roster.last?.id { Divider() }
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func row(_ line: SquadCommand.RosterLine, now: Date) -> some View {
        HStack(spacing: 12) {
            Image(systemName: command.orderTargets.contains(line.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(command.orderTargets.contains(line.id) ? Color.accentColor : .secondary)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
                .onTapGesture { command.toggleTarget(line.id) }
                .accessibilityLabel(command.orderTargets.contains(line.id) ? "Picked for the next order" : "Pick for the next order")
            Circle().fill(line.online ? Color.green : Color.gray.opacity(0.5)).frame(width: 10, height: 10)
                .accessibilityLabel(line.online ? "Linked" : "Offline")
            VStack(alignment: .leading, spacing: 2) {
                Text(line.member.name).font(.body.weight(.semibold))
                Text(line.online ? (line.member.role == .gunner ? "Gunner" : "Member") : "Offline")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            positionText(line.position, now: now)
            Menu {
                if line.member.role == .gunner {
                    Button("Make member") { command.setRole(line.id, .member) }
                } else {
                    Button("Make gunner") { command.setRole(line.id, .gunner) }
                }
                Button("Remove from squad", role: .destructive) { command.remove(line.id) }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder private func positionText(_ p: MemberPosition?, now: Date) -> some View {
        if let p {
            let age = max(0, now.timeIntervalSince(p.time))
            let stale = age > SquadCommand.staleAfter
            VStack(alignment: .trailing, spacing: 2) {
                Text(age < 2 ? "Position now" : "Position \(Int(age)) s ago")
                    .font(.footnote.weight(stale ? .semibold : .regular))
                    .foregroundStyle(stale ? .orange : .primary)
                Text(String(format: "±%.0f m", p.accuracy)).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("No position yet").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let host = command.host {
                let s = host.status(now: Date())
                Text("Squad status").font(.headline)
                LabeledContent("Hole", value: s.hole.map { "\($0)" } ?? "Not started")
                LabeledContent("Total", value: String(format: "%.1f", s.total))
                if !s.holds.isEmpty {
                    Text("Holds").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    ForEach(s.holds, id: \.self) { h in
                        Label(h.description, systemImage: "hand.raised.fill").font(.footnote).foregroundStyle(.orange)
                    }
                    if s.holds.contains(.noMatch) {
                        Text("A squad on its own has no match host, so firing data stays held. That's expected in practice; holds never stop orders, locks or the map.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    /// "K7Q2MX" → "K7Q 2MX", easier to read out.
    static func spaced(_ code: String) -> String {
        code.count == 6 ? code.prefix(3) + " " + code.suffix(3) : code
    }
}
