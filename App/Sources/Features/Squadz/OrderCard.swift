import SwiftUI
import GroupKit

/// One of the squad leader's orders on a member's phone: what to do, the note, where (distance
/// and direction from here), and Seen / Done / Can't.
struct OrderCard: View {
    @EnvironmentObject private var membership: SquadMembership
    let order: Order
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 8) {
            HStack(alignment: .firstTextBaseline) {
                Label(order.kind.title, systemImage: order.kind.systemImage)
                    .font(compact ? .subheadline.weight(.bold) : .headline)
                Spacer()
                Text(order.to == nil ? "Team" : "You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            if !order.text.isEmpty {
                Text(order.text).font(compact ? .footnote : .body).lineLimit(compact ? 2 : nil)
            }
            if order.at != nil {
                Label(membership.directions(to: order) ?? "Place on the map (waiting for GPS)", systemImage: "location.north.line.fill")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                answer("Seen", .seen, tint: .blue)
                answer("Done", .done, tint: .green)
                answer("Can't", .cannot, tint: .red)
            }
        }
    }

    private func answer(_ title: String, _ r: OrderAck.Response, tint: Color) -> some View {
        Button(title) { membership.ack(order, r) }
            .buttonStyle(.bordered)
            .tint(tint)
            .controlSize(compact ? .small : .regular)
            .disabled(r == .seen && membership.answers[order.id] == .seen)
    }
}

/// The newest open order, across the top of any screen while in a squad.
struct OrderBanner: View {
    @EnvironmentObject private var membership: SquadMembership

    var body: some View {
        if membership.isInSquad, let order = membership.orders.last {
            VStack(alignment: .leading, spacing: 4) {
                OrderCard(order: order, compact: true)
                if membership.orders.count > 1 {
                    Text("\(membership.orders.count - 1) more in Join squad").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.6), lineWidth: 1))
            .shadow(radius: 6)
            .padding(.horizontal, 12)
            .frame(maxWidth: 520)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
