import SwiftUI
import RoundKit
import GroupKit
import GroupLink

/// Play → v3 Squadz → Join squad: pick a commander's iPad, type its code, and you're in. While
/// joined the phone shows the squad's status and reports its position. No firing data, ever.
struct JoinSquadView: View {
    @EnvironmentObject private var membership: SquadMembership
    @AppStorage(Settings.playerNameKey) private var name = Settings.defaultPlayerName
    @State private var picked: GroupBrowser.Found?
    @State private var code = ""

    var body: some View {
        Form {
            switch membership.state {
            case .joined, .disconnected:
                joinedSections
            case let .connecting(squad):
                Section {
                    HStack { ProgressView(); Text("Joining \(squad)…") }
                    Button("Cancel", role: .cancel) { membership.leave(sendBye: false) }
                }
            default:
                problemSection
                pickSections
            }
        }
        .navigationTitle("Join squad")
        .onAppear { membership.startBrowsing() }
        .onDisappear { membership.stopBrowsing() }
    }

    // MARK: Before joining

    @ViewBuilder private var problemSection: some View {
        switch membership.state {
        case let .refused(reason):
            Section {
                Label(reason, systemImage: "hand.raised.fill").foregroundStyle(.red)
            } header: { Text("The squad said no") }
        case let .failed(reason):
            Section {
                Label(reason, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Button("Try again") { membership.retry() }
            } header: { Text("Couldn't join") }
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var pickSections: some View {
        Section {
            TextField("Your name", text: $name).textInputAutocapitalization(.words)
        } header: {
            Text("You")
        }
        Section {
            if membership.found.isEmpty {
                HStack { ProgressView(); Text("Looking for squads on this Wi-Fi…").foregroundStyle(.secondary) }
            }
            ForEach(membership.found) { squad in
                Button {
                    picked = squad
                } label: {
                    HStack {
                        Label(squad.name, systemImage: "person.3.fill")
                        Spacer()
                        if !squad.isCompatible {
                            Text("Other app version").font(.caption).foregroundStyle(.orange)
                        } else if picked == squad {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(!squad.isCompatible)
            }
            if let error = membership.browseError {
                Text("Can't look for squads: \(error)").font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("Squads nearby")
        } footer: {
            Text("The commander's iPad must be open on Command a squad, on the same Wi-Fi (or nearby, with no router). If iOS asks to find devices on your local network, allow it.")
        }
        Section {
            TextField("Join code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .font(.system(.title2, design: .monospaced))
            Button {
                if let picked { membership.join(picked, code: code, name: name) }
            } label: {
                Label(picked.map { "Join \($0.name)" } ?? "Pick a squad above", systemImage: "arrow.right.circle.fill")
            }
            .disabled(picked == nil || JoinCode.normalized(code).count != 6 || name.trimmingCharacters(in: .whitespaces).isEmpty)
        } header: {
            Text("Code")
        } footer: {
            Text("Six letters and numbers, shown big on the commander's iPad.")
        }
    }

    // MARK: Joined

    @ViewBuilder private var joinedSections: some View {
        if membership.state == .disconnected {
            Section {
                Label("Lost the link to the squad's iPad.", systemImage: "wifi.exclamationmark").foregroundStyle(.orange)
                Button("Rejoin") { membership.retry() }
            }
        }
        Section {
            LabeledContent("Squad", value: membership.squadName ?? "—")
            if let me = membership.me {
                LabeledContent("You", value: me.name)
                LabeledContent("Role", value: me.role == .gunner ? "Gunner" : "Member")
            }
        } header: {
            Text(membership.state == .joined ? "Welcome" : "Squad")
        }
        if let s = membership.status {
            Section {
                LabeledContent("Hole", value: s.hole.map { "\($0)" } ?? "Not started")
                if let phase = s.phase { LabeledContent("Phase", value: Self.label(phase, walkingOut: s.walkingOut)) }
                LabeledContent("Total", value: String(format: "%.1f (%@%.1f)", s.total, s.toPar >= 0 ? "+" : "", s.toPar))
                LabeledContent("Members", value: "\(s.squad.members.count)")
                if let r = membership.spotRequest {
                    Label("Round \(r.round) is in the air. Spotting from phones comes next.", systemImage: "scope")
                        .foregroundStyle(.secondary).font(.footnote)
                }
            } header: {
                Text("Squad status")
            }
            if !s.holds.isEmpty {
                Section {
                    ForEach(s.holds, id: \.self) { h in
                        Label(h.description, systemImage: "hand.raised.fill").foregroundStyle(.orange)
                    }
                } header: {
                    Text("Holds")
                }
            }
        }
        Section {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if membership.locationDenied {
                    Text("Location is off for SpudGunGolf. The commander needs your position to keep the fan clear: turn it on in Settings.")
                        .foregroundStyle(.red)
                } else if let fix = membership.lastFix {
                    LabeledContent("GPS", value: String(format: "±%.0f m", fix.horizontalAccuracy))
                    if let sent = membership.lastSent {
                        LabeledContent("Last sent", value: "\(Int(max(0, context.date.timeIntervalSince(sent)))) s ago")
                    }
                } else {
                    Text("Waiting for GPS…").foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Your position")
        } footer: {
            Text("Sent to the commander every \(Int(SquadMembership.positionInterval)) seconds while you're in the squad.")
        }
        Section {
            Button("Leave the squad", role: .destructive) { membership.leave() }
        }
    }

    static func label(_ phase: HolePlay.Phase, walkingOut: Bool) -> String {
        if walkingOut { return "Cease fire, walking out" }
        switch phase {
        case .setup: return "Setting up"
        case .firing: return "Firing"
        case .ceased: return "Verifying"
        case .finished: return "Finished"
        }
    }
}
