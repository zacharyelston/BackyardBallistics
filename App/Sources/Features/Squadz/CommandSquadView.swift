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

/// The lobby: the code, the QR code and the roster, side by side when there's room.
struct SquadLobbyView: View {
    @EnvironmentObject private var command: SquadCommand
    @State private var confirmEnd = false

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > 700
            ScrollView {
                if wide {
                    HStack(alignment: .top, spacing: 24) {
                        codePanel.frame(width: min(360, geo.size.width * 0.38))
                        VStack(spacing: 20) { rosterPanel; statusPanel }
                    }
                    .padding(24)
                } else {
                    VStack(spacing: 20) { codePanel; rosterPanel; statusPanel }.padding()
                }
            }
        }
        .background(Color(.systemGroupedBackground))
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

    private var codePanel: some View {
        VStack(spacing: 16) {
            if let host = command.host {
                Text(host.player).font(.title.weight(.bold))
                Text("Join code").font(.subheadline).foregroundStyle(.secondary)
                Text(Self.spaced(host.joinCode))
                    .font(.system(size: 44, weight: .heavy, design: .monospaced))
                    .minimumScaleFactor(0.5).lineLimit(1)
                    .textSelection(.enabled)
                QRCodeView(text: host.joinCode)
                    .frame(maxWidth: 220, maxHeight: 220)
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
                }
                Text("Playing holes over the link (ranging, Fired, spotting) comes in the next step, G5.")
                    .font(.footnote).foregroundStyle(.secondary).padding(.top, 4)
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
