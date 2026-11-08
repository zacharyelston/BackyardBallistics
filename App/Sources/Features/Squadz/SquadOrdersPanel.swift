import SwiftUI
import CoreGeo
import GroupKit

/// The squad leader's orders: pick the team or members (here, in the roster, or on the map), tap
/// a kind with an optional short note and place, and watch each member's answer come back.
/// Orders are tasking only; they never carry firing data.
struct SquadOrdersPanel: View {
    @EnvironmentObject private var command: SquadCommand
    @State private var text = ""

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Orders").font(.headline)
            if let host = command.host {
                recipients(host)
                TextField("Note (optional)", text: $text, axis: .vertical)
                    .lineLimit(1...3)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: text) { _, t in if t.count > Order.maxText { text = String(t.prefix(Order.maxText)) } }
                placeRow
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Order.Kind.allCases, id: \.self) { kind in
                        Button {
                            if command.sendOrder(kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines)) { text = "" }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: kind.systemImage).font(.title3)
                                Text(kind.title).font(.caption2.weight(.semibold))
                                    .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                            }
                            .frame(maxWidth: .infinity, minHeight: 54)
                        }
                        .buttonStyle(.bordered)
                        .disabled(kind == .note && text.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                recent(host)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: Who it's for

    private func recipients(_ host: SquadHost) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(command.orderTargets.isEmpty ? "To: the whole team" : "To: \(names(command.orderTargets, host))")
                .font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("Team", on: command.orderTargets.isEmpty) { command.orderTargets = [] }
                    ForEach(host.round.squad.members) { m in
                        chip(m.name, on: command.orderTargets.contains(m.id)) { command.toggleTarget(m.id) }
                    }
                }
            }
            Text("Tap names here, in the roster or on the map to pick members.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: Where

    @ViewBuilder private var placeRow: some View {
        HStack {
            if command.placingOrder {
                Label("Tap the map to set the place", systemImage: "hand.tap.fill").foregroundStyle(.orange)
                Spacer()
                Button("Cancel") { command.placingOrder = false }
            } else if let p = command.orderPlace {
                Label(String(format: "Place set (%.5f, %.5f)", p.latitude, p.longitude), systemImage: "mappin.circle.fill")
                    .font(.footnote)
                Spacer()
                Button("Clear") { command.orderPlace = nil }
            } else {
                Button {
                    command.placingOrder = true
                } label: {
                    Label("Set a place on the map", systemImage: "mappin.and.ellipse")
                }
                Spacer()
            }
        }
        .font(.footnote)
        Text("A place goes with Move to, Range the pole and Capture.").font(.caption).foregroundStyle(.secondary)
    }

    // MARK: Answers

    @ViewBuilder private func recent(_ host: SquadHost) -> some View {
        let orders = Array(host.orders.suffix(8).reversed())
        if !orders.isEmpty {
            Divider().padding(.vertical, 4)
            Text("Recent").font(.subheadline.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(orders) { order in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(order.kind.title, systemImage: order.kind.systemImage).font(.footnote.weight(.semibold))
                                Spacer()
                                Text(Self.age(order.time, now: context.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            if !order.text.isEmpty { Text(order.text).font(.footnote) }
                            HStack(spacing: 6) {
                                ForEach(host.recipients(of: order)) { m in
                                    answer(m.name, host.acks[order.id]?[m.id])
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func answer(_ name: String, _ r: OrderAck.Response?) -> some View {
        let (label, color): (String, Color) = {
            switch r {
            case .seen: return ("seen", .blue)
            case .done: return ("done", .green)
            case .cannot: return ("can't", .red)
            case nil: return ("…", .secondary)
            }
        }()
        return Text("\(name) \(label)").font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func names(_ ids: Set<MemberID>, _ host: SquadHost) -> String {
        host.round.squad.members.filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    static func age(_ d: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(d)))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}
