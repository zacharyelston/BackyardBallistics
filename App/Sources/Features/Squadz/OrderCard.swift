import SwiftUI
import MapKit
import CoreGeo
import GroupKit

// A member's phone: the squad leader's orders. Each order says what, where (a mini map and a
// pointer that turns with the phone), and opens the tool it needs, so a member can flip between
// orders: move to A, then range from B.

/// The screen an order needs on the phone.
enum OrderTool {
    /// The reticle ranging screen (its Send to squad menu sends the lock).
    case ranging
    /// The pointer and map, to walk to the order's place.
    case goTo
    /// The spotter card: call the round in flight.
    case spotting
    case none

    init(_ order: Order) {
        switch order.kind {
        case .rangeFrom: self = .ranging
        case .spot: self = .spotting
        case .moveTo, .capture, .holdPosition, .returnToFiringPoint: self = order.at == nil ? .none : .goTo
        case .note: self = .none
        }
    }

    var title: String {
        switch self {
        case .ranging: return "Open ranging"
        case .goTo: return "Go there"
        case .spotting: return "Spot"
        case .none: return ""
        }
    }

    var systemImage: String {
        switch self {
        case .ranging: return "scope"
        case .goTo: return "location.north.line.fill"
        case .spotting: return "eye.fill"
        case .none: return ""
        }
    }

    @ViewBuilder func destination(_ order: Order) -> some View {
        switch self {
        case .ranging: ReticleRangingView()
        case .goTo: GoToView(order: order)
        case .spotting: SpotterCard(order: order)
        case .none: EmptyView()
        }
    }
}

/// An arrow that points at the order's place, turning with the phone, and how far it is.
struct OrderPointer: View {
    @EnvironmentObject private var membership: SquadMembership
    let order: Order
    var size: CGFloat = 44

    var body: some View {
        if let p = membership.pointer(to: order) {
            HStack(spacing: 10) {
                Image(systemName: "location.north.fill")
                    .font(.system(size: size, weight: .bold))
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(p.bearing - (membership.heading ?? 0)))
                    .animation(.easeOut(duration: 0.2), value: membership.heading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.distance(p.distance)).font(size > 40 ? .title.weight(.bold) : .headline).monospacedDigit()
                    Text(membership.heading == nil ? String(format: "%03.0f° (north up: no compass yet)", p.bearing)
                                                   : String(format: "%03.0f°", p.bearing))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } else if order.at != nil {
            Label("Waiting for GPS…", systemImage: "location.slash").font(.footnote).foregroundStyle(.secondary)
        }
    }

    static func distance(_ m: Double) -> String { m < 1000 ? String(format: "%.0f m", m) : String(format: "%.2f km", m / 1000) }
}

/// The order's place and this phone on a small satellite map.
struct OrderMiniMap: View {
    @EnvironmentObject private var membership: SquadMembership
    let order: Order

    var body: some View {
        if let at = order.at {
            Map(initialPosition: .automatic) {
                Annotation(order.kind.title, coordinate: at.coordinate, anchor: .bottom) {
                    Image(systemName: order.kind.systemImage)
                        .font(.caption.weight(.bold)).foregroundStyle(.white)
                        .padding(6).background(.orange, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 1.5))
                }
                if let fix = membership.lastFix {
                    Annotation("You", coordinate: fix.coordinate) {
                        Circle().fill(.blue).frame(width: 12, height: 12).overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                    MapPolyline(coordinates: [fix.coordinate, at.coordinate])
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .mapStyle(.hybrid)
        }
    }
}

/// One order, compact: what, the note, the pointer, its tool, and Seen / Done / Can't. Seen tells
/// the commander you've got it and opens the tool the order needs: ranging for Range the pole, the
/// spotter card for Spot, Go there for an order with a place.
struct OrderCard: View {
    @EnvironmentObject private var membership: SquadMembership
    @EnvironmentObject private var reticleLog: ReticleLogStore
    let order: Order
    var compact = false
    /// When set, the tool opens through this (the banner opens the orders screen at the tool);
    /// otherwise it opens in a sheet over this screen.
    var onOpen: (() -> Void)?
    @State private var showingTool = false

    private var tool: OrderTool { OrderTool(order) }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            // The order is the title; tapping it opens the tool it needs.
            Button {
                if tool != .none { openTool() }
            } label: {
                // Plain style: a borderless button would tint the whole title orange.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: order.kind.systemImage).foregroundStyle(.orange)
                        .font(compact ? .subheadline.weight(.bold) : .title3.weight(.bold))
                    Text(order.kind.title).foregroundStyle(.primary)
                        .font(compact ? .subheadline.weight(.bold) : .title3.weight(.bold))
                    Text(order.to == nil ? "Team" : "You")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                    Spacer(minLength: 4)
                    if tool != .none {
                        Image(systemName: "chevron.right").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tool == .none)
            .accessibilityHint(tool == .none ? "" : "Opens \(Self.toolName(tool))")
            if !order.text.isEmpty {
                Text(order.text).font(compact ? .footnote : .body).lineLimit(compact ? 2 : nil)
            }
            if order.at != nil { OrderPointer(order: order, size: compact ? 22 : 34) }
            // The commands: one even row that never wraps.
            HStack(spacing: 8) {
                answer("Seen", .seen, tint: .blue)
                answer("Done", .done, tint: .green)
                answer("Can't", .cannot, tint: .red)
            }
            if tool != .none && !compact {
                Text("Tap the order or Seen to open \(Self.toolName(tool)).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showingTool) {
            NavigationStack {
                tool.destination(order)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { showingTool = false } } }
            }
            .environmentObject(membership)
            .environmentObject(reticleLog)
        }
    }

    private func openTool() {
        if let onOpen { onOpen() } else { showingTool = true }
    }

    private func answer(_ title: String, _ r: OrderAck.Response, tint: Color) -> some View {
        Button {
            membership.ack(order, r)
            if r == .seen && tool != .none { openTool() }
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).fixedSize()
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(tint)
        .controlSize(compact ? .small : .regular)
        // Seen stays live while it opens a tool, so it can bring the tool back.
        .disabled(r == .seen && tool == .none && membership.answers[order.id] == .seen)
    }

    static func toolName(_ t: OrderTool) -> String {
        switch t {
        case .ranging: return "the ranging screen"
        case .spotting: return "the spotter card"
        case .goTo: return "the pointer to the place"
        case .none: return ""
        }
    }
}

/// An order in full: the map, the pointer, the tool, and the answers.
struct OrderDetailView: View {
    @EnvironmentObject private var membership: SquadMembership
    let order: Order

    var body: some View {
        List {
            Section {
                OrderCard(order: order)
            }
            if order.at != nil {
                Section {
                    OrderMiniMap(order: order).frame(height: 240).listRowInsets(EdgeInsets())
                } header: {
                    Text("Where")
                }
            }
        }
        .navigationTitle(order.kind.title)
    }
}

/// Walk to an order's place: a big pointer that turns with the phone, the distance, and the map.
struct GoToView: View {
    @EnvironmentObject private var membership: SquadMembership
    let order: Order

    var body: some View {
        VStack(spacing: 20) {
            if !order.text.isEmpty { Text(order.text).font(.title3).multilineTextAlignment(.center) }
            OrderPointer(order: order, size: 96)
            if let p = membership.pointer(to: order), p.distance < 5 {
                Label("You're there", systemImage: "checkmark.circle.fill").font(.headline).foregroundStyle(.green)
            }
            OrderMiniMap(order: order).clipShape(RoundedRectangle(cornerRadius: 16))
            HStack {
                Button("Done") { membership.ack(order, .done) }.buttonStyle(.borderedProminent).tint(.green)
                Button("Can't") { membership.ack(order, .cannot) }.buttonStyle(.bordered).tint(.red)
            }
        }
        .padding()
        .navigationTitle(order.kind.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// All of this member's open orders, each opening its detail and its tool. Back flips between them.
struct OrdersHub: View {
    @EnvironmentObject private var membership: SquadMembership
    var start: Order?
    /// Open `start`'s tool straight away (Back then shows the order, then the list).
    var openTool = false
    @Environment(\.dismiss) private var dismiss
    @State private var path: [Route] = []

    enum Route: Hashable {
        case order(UUID)
        case tool(UUID)
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if membership.orders.isEmpty {
                    Text("No open orders.").foregroundStyle(.secondary)
                }
                ForEach(membership.orders.reversed()) { order in
                    NavigationLink(value: Route.order(order.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(order.kind.title, systemImage: order.kind.systemImage).font(.headline)
                            if !order.text.isEmpty { Text(order.text).font(.footnote).lineLimit(2) }
                            if order.at != nil { OrderPointer(order: order, size: 18) }
                        }
                    }
                }
            }
            .navigationTitle("Orders")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case let .order(id):
                    if let order = membership.orders.first(where: { $0.id == id }) {
                        OrderDetailView(order: order)
                    } else {
                        Text("That order is finished.").foregroundStyle(.secondary)
                    }
                case let .tool(id):
                    if let order = membership.orders.first(where: { $0.id == id }) {
                        OrderTool(order).destination(order)
                    }
                }
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close") { dismiss() } } }
        }
        .onAppear {
            guard let start else { return }
            path = openTool && OrderTool(start) != .none ? [.order(start.id), .tool(start.id)] : [.order(start.id)]
        }
    }
}

/// The newest open order along the bottom of any screen while in a squad. Open goes to the
/// orders screen at that order.
struct OrderBanner: View {
    @EnvironmentObject private var membership: SquadMembership
    @EnvironmentObject private var reticleLog: ReticleLogStore
    @State private var opened: Order?
    @State private var openTool = false

    var body: some View {
        Group {
            if membership.isInSquad, !membership.showingJoinScreen, let order = membership.orders.last {
                VStack(alignment: .leading, spacing: 4) {
                    OrderCard(order: order, compact: true, onOpen: { openTool = true; opened = order })
                    if membership.orders.count > 1 {
                        Button("\(membership.orders.count - 1) more order\(membership.orders.count > 2 ? "s" : "")") { openTool = false; opened = nil; opened = order }
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(12)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.orange.opacity(0.6), lineWidth: 1))
                .shadow(radius: 6)
                .padding(.horizontal, 12)
                .frame(maxWidth: 560)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $opened) { order in
            OrdersHub(start: openTool ? order : nil, openTool: openTool)
                .environmentObject(membership)
                .environmentObject(reticleLog)
        }
    }
}
