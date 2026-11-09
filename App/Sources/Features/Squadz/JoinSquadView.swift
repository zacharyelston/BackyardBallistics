import SwiftUI
import RoundKit
import GroupKit
import GroupLink

/// Play → Join squad: pick a commander's iPad, type its code, and you're in. While
/// joined the phone shows the squad's status and reports its position. No firing data, ever.
struct JoinSquadView: View {
    @EnvironmentObject private var membership: SquadMembership
    @AppStorage(Settings.playerNameKey) private var name = Settings.defaultPlayerName
    @State private var picked: GroupBrowser.Found?
    @State private var code = ""
    @State private var scanning = false
    @State private var showingDetails = false
    @State private var confirmLeave = false

    var body: some View {
        Form {
            switch membership.state {
            case .joined, .reconnecting:
                joinedSections
            case let .connecting(squad):
                Section {
                    HStack { ProgressView(); Text("Joining \(squad)…") }
                    Button("Cancel", role: .cancel) { membership.leave() }
                }
            default:
                problemSection
                pickSections
            }
        }
        .navigationTitle(membership.isInSquad ? "Squad " + (membership.squadName ?? "") : "Join squad")
        .navigationBarTitleDisplayMode(membership.isInSquad ? .inline : .large)
        .toolbar {
            if membership.isInSquad {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Squad details", systemImage: "person.3") { showingDetails = true }
                        Button("Leave squad", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmLeave = true }
                    } label: { Label("Squad", systemImage: "ellipsis.circle") }
                }
            }
        }
        .sheet(isPresented: $showingDetails) {
            NavigationStack {
                Form { membershipDetails }
                    .navigationTitle("Squad details")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showingDetails = false } } }
            }
        }
        .confirmationDialog("Leave the squad?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Leave squad", role: .destructive) { membership.leave() }
        } message: { Text("Your position and reports will stop being sent to the commander.") }
        .onAppear { membership.showingJoinScreen = true }
        .onDisappear { membership.showingJoinScreen = false }
        .sheet(isPresented: $scanning) {
            JoinCodeScanSheet { scanned in
                code = scanned
                // One squad nearby: that's the one the code is for.
                let compatible = membership.found.filter(\.isCompatible)
                if picked == nil, compatible.count == 1 { picked = compatible[0] }
            }
        }
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
            if JoinCodeScanner.isAvailable {
                Button {
                    scanning = true
                } label: {
                    Label("Scan code", systemImage: "qrcode.viewfinder")
                }
            }
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
            Text("Scan the QR code on the commander's iPad, or type the six letters and numbers shown under it.")
        }
    }

    // MARK: Joined

    @ViewBuilder private var joinedSections: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(membership.state == .joined ? "Connected" : "Reconnecting",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(membership.state == .joined ? .green : .orange)
                    Spacer()
                    if case .reconnecting = membership.state {
                        Button("Try now") { membership.retry() }.frame(minHeight: 44)
                    } else if let me = membership.me {
                        Text(me.name).foregroundStyle(.secondary)
                    }
                }
                .font(.subheadline)
                if case let .reconnecting(why) = membership.state {
                    Text(why).font(.caption).foregroundStyle(.secondary)
                }
                positionStatus
            }
            .padding(.vertical, 4)
        }
        if let order = membership.orders.last {
            Section("Current task") {
                OrderCard(order: order)
                    .padding(.vertical, 8)
                if order.at != nil {
                    NavigationLink { OrderDetailView(order: order) } label: {
                        Label("Map and details", systemImage: "map")
                    }
                }
            }
        } else {
            Section {
                Label("No pending tasks", systemImage: "checkmark.circle")
                Text("New orders from your commander appear here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        if membership.orders.count > 1 {
            Section("Other tasks") {
                ForEach(membership.orders.dropLast().reversed()) { order in
                    NavigationLink { OrderDetailView(order: order) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(order.kind.title, systemImage: order.kind.systemImage).font(.headline)
                            if !order.text.isEmpty { Text(order.text).font(.footnote).foregroundStyle(.secondary) }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
        }
        if let s = membership.status, !s.holds.isEmpty {
            Section("Holds") {
                ForEach(s.holds, id: \.self) { hold in
                    Label(hold.description, systemImage: "hand.raised.fill")
                        .foregroundStyle(.orange).font(.footnote)
                }
            }
        }
        Section {
            NavigationLink { FieldNoteView() } label: {
                Label("Send a field note", systemImage: "note.text.badge.plus")
            }
            ForEach(membership.sentToLeader.prefix(3)) { s in
                SentItemRow(title: s.title, receipt: s.receipt)
            }
        } header: {
            Text("Field notes")
        } footer: {
            Text("A note (and a photo) pinned where you stand, to your squad leader, who passes it on to the Theater.")
        }
    }

    @ViewBuilder private var positionStatus: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if membership.locationDenied {
                Label("Location is off. Enable it in Settings to share your position.", systemImage: "location.slash")
                    .foregroundStyle(.red)
            } else if let fix = membership.lastFix {
                let age = membership.lastSent.map { max(0, context.date.timeIntervalSince($0)) }
                Text(String(format: "GPS ±%.0f m", fix.horizontalAccuracy)
                     + (age.map { " · sent \(Int($0)) s ago" } ?? " · not sent yet"))
                    .foregroundStyle(age.map { $0 > 15 } ?? true ? .orange : .secondary)
            } else {
                Label("Waiting for GPS…", systemImage: "location")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
    }

    @ViewBuilder private var membershipDetails: some View {
        Section("Membership") {
            LabeledContent("Squad", value: membership.squadName ?? "—")
            if let me = membership.me {
                LabeledContent("You", value: me.name)
                LabeledContent("Role", value: me.role == .gunner ? "Gunner" : "Member")
            }
        }
        if let s = membership.status {
            Section {
                LabeledContent("Hole", value: s.hole.map { "\($0)" } ?? "Not started")
                if let phase = s.phase { LabeledContent("Phase", value: Self.label(phase, walkingOut: s.walkingOut)) }
                LabeledContent("Total", value: String(format: "%.1f (%@%.1f)", s.total, s.toPar >= 0 ? "+" : "", s.toPar))
                LabeledContent("Members", value: "\(s.squad.members.count)")
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
        Section("Your position") { positionStatus }
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
