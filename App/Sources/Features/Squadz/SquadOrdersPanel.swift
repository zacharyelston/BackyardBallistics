import SwiftUI
import CoreGeo
import GroupKit

/// The squad leader's orders, one step at a time: 1 who (here, in the roster, or on the map),
/// 2 what kind, 3 where (a fresh tap on the map, for kinds that take a place), 4 Send. Nothing is
/// sent until Send, and nothing carries over from the last order. Below, each recipient's answer.
/// Orders are tasking only; they never carry firing data.
struct SquadOrdersPanel: View {
    @EnvironmentObject private var command: SquadCommand
    @State private var text = ""

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Orders").font(.headline)
                Spacer()
                if command.orderKind != nil || !command.orderTargets.isEmpty {
                    Button("Clear") { command.clearOrderDraft(); text = "" }.font(.footnote)
                }
            }
            if let host = command.host {
                step(1, "Who") { recipients(host) }
                step(2, "What") { kinds }
                if let kind = command.orderKind {
                    if kind.takesPlace { step(3, "Where") { placeRow } }
                    step(kind.takesPlace ? 4 : 3, "Note and send") { sendRow(host, kind: kind) }
                }
                if let problem = command.orderProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.red)
                }
                recent(host)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private func step<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(n). \(title)").font(.caption.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
            content()
        }
    }

    // MARK: 1. Who

    private func recipients(_ host: SquadHost) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("Team", on: command.orderTargets.isEmpty) { command.orderTargets = [] }
                    ForEach(host.round.squad.members) { m in
                        chip(m.name, on: command.orderTargets.contains(m.id)) { command.toggleTarget(m.id) }
                    }
                }
            }
            Text(command.orderTargets.isEmpty ? "The whole team. Tap names, roster rows or dots on the map to pick people."
                                              : "To \(names(command.orderTargets, host)).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chip(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.footnote.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(on ? Color.accentColor : Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(on ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 2. What

    private var kinds: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Order.Kind.allCases, id: \.self) { kind in
                let chosen = command.orderKind == kind
                Button {
                    command.chooseKind(chosen ? nil : kind)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: kind.systemImage).font(.title3)
                        Text(kind.title).font(.caption2.weight(.semibold))
                            .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity, minHeight: 54)
                }
                .buttonStyle(.bordered)
                .tint(chosen ? .orange : .gray)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange, lineWidth: chosen ? 2 : 0))
            }
        }
    }

    // MARK: 3. Where

    @ViewBuilder private var placeRow: some View {
        if command.placingOrder || command.orderPlace == nil {
            HStack {
                Label("Tap the map where you want them", systemImage: "hand.tap.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                Spacer()
                if !command.placingOrder { Button("Tap the map") { command.placingOrder = true }.font(.footnote) }
            }
        } else if let p = command.orderPlace {
            HStack {
                Label(String(format: "Set (%.5f, %.5f)", p.latitude, p.longitude), systemImage: "mappin.circle.fill")
                    .font(.footnote)
                Spacer()
                Button("Move it") { command.placingOrder = true }.font(.footnote)
            }
        }
    }

    // MARK: 4. Send

    private func sendRow(_ host: SquadHost, kind: Order.Kind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(kind == .note ? "Note" : "Note (optional)", text: $text, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .onChange(of: text) { _, t in if t.count > Order.maxText { text = String(t.prefix(Order.maxText)) } }
            Button {
                if command.sendOrder(text: text) { text = "" }
            } label: {
                Label("Send \(kind.title) to \(command.orderTargets.isEmpty ? "the team" : names(command.orderTargets, host))",
                      systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!command.canSend(text: text))
        }
    }

    // MARK: Answers

    @ViewBuilder private func recent(_ host: SquadHost) -> some View {
        let orders = Array(host.orders.suffix(8).reversed())
        if !orders.isEmpty {
            Divider().padding(.vertical, 2)
            Text("Sent").font(.subheadline.weight(.semibold))
            TimelineView(.periodic(from: .now, by: 10)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(orders) { order in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Label(order.kind.title, systemImage: order.kind.systemImage).font(.footnote.weight(.semibold))
                                if order.at != nil { Image(systemName: "mappin").font(.caption).foregroundStyle(.secondary) }
                                Spacer()
                                Text(Self.age(order.time, now: context.date)).font(.caption).foregroundStyle(.secondary)
                            }
                            if !order.text.isEmpty { Text(order.text).font(.footnote) }
                            FlowAnswers(items: host.recipients(of: order).map { ($0.name, host.acks[order.id]?[$0.id]) })
                        }
                    }
                }
            }
        }
    }

    private func names(_ ids: Set<MemberID>, _ host: SquadHost) -> String {
        host.round.squad.members.filter { ids.contains($0.id) }.map(\.name).joined(separator: ", ")
    }

    static func age(_ d: Date, now: Date) -> String {
        let s = Int(max(0, now.timeIntervalSince(d)))
        return s < 60 ? "\(s) s ago" : "\(s / 60) min ago"
    }
}

/// Each recipient's answer to an order, as small coloured capsules that wrap.
private struct FlowAnswers: View {
    let items: [(String, OrderAck.Response?)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { capsules }
            VStack(alignment: .leading, spacing: 4) { capsules }
        }
    }

    @ViewBuilder private var capsules: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
            let (label, color): (String, Color) = {
                switch item.1 {
                case .seen: return ("seen", .blue)
                case .done: return ("done", .green)
                case .cannot: return ("can't", .red)
                case nil: return ("no answer yet", .secondary)
                }
            }()
            Text("\(item.0): \(label)").font(.caption2.weight(.semibold))
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
    }
}
