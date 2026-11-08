import SwiftUI
import RangingKit
import GroupKit

/// The spotter card on a member's phone: watch the round land and call it. It follows the squad:
/// it waits for the gunner's Fired, then asks for this round's call (short, over or range correct),
/// and stays up for the next round. The gunner can call Fired from here too. No firing data.
struct SpotterCard: View {
    @EnvironmentObject private var membership: SquadMembership
    var order: Order?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            if let order, !order.text.isEmpty {
                Text(order.text).font(.headline).multilineTextAlignment(.center)
            }
            if let order, order.at != nil {
                OrderPointer(order: order, size: 30)
            }
            roundState
            if let r = membership.spotRequest {
                VStack(spacing: 12) {
                    callButton(.short, r, tint: .blue, systemImage: "arrow.down.circle.fill")
                    callButton(.rangeCorrect, r, tint: .green, systemImage: "scope")
                    callButton(.over, r, tint: .orange, systemImage: "arrow.up.circle.fill")
                }
            }
            if membership.isGunner, let f = membership.nextRoundToFire {
                Button {
                    membership.sendFired()
                } label: {
                    Label("Fired round \(f.round)", systemImage: "flame.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
            }
            Spacer()
            if let order {
                HStack {
                    Button("Done spotting") { membership.ack(order, .done); dismiss() }.buttonStyle(.bordered).tint(.green)
                    Button("Can't") { membership.ack(order, .cannot); dismiss() }.buttonStyle(.bordered).tint(.red)
                }
            }
        }
        .padding()
        .navigationTitle("Spot")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private var roundState: some View {
        if let r = membership.spotRequest {
            VStack(spacing: 4) {
                Text("Round \(r.round) is in the air").font(.title2.weight(.bold))
                if let last = membership.lastSpot, last.round == r.round {
                    Label("You called \(last.call.label). Tap again to change it.", systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                } else {
                    Text("Watch where it lands, then call it.").font(.footnote).foregroundStyle(.secondary)
                }
            }
        } else if let s = membership.status, s.phase == .firing, !s.walkingOut {
            VStack(spacing: 4) {
                Text("Waiting for Fired").font(.title2.weight(.bold))
                if let last = membership.lastSpot {
                    Text("Round \(last.round): you called \(last.call.label).").font(.footnote).foregroundStyle(.secondary)
                }
                Text(membership.isGunner ? "You're the gunner: call Fired when the round is away." : "The card lights up when the gunner calls Fired.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        } else {
            VStack(spacing: 4) {
                Text("Not firing yet").font(.title2.weight(.bold))
                Text("The squad hasn't started a mission. Keep this open; it lights up when a round is fired.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    private func callButton(_ call: RangeCall, _ r: SpotRequest, tint: Color, systemImage: String) -> some View {
        let chosen = membership.lastSpot?.round == r.round && membership.lastSpot?.call == call
        return Button {
            membership.sendSpot(call)
        } label: {
            Label(call.label, systemImage: systemImage)
                .font(.title3.weight(.bold))
                .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.borderedProminent)
        .tint(chosen ? tint : tint.opacity(0.55))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white, lineWidth: chosen ? 3 : 0))
    }
}
