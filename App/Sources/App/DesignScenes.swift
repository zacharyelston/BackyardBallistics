#if DEBUG
import SwiftUI
import CoreLocation
import CoreGeo
import CourseKit
import GroupKit

// Design scenes: launch the app straight into one screen with made-up squad data, so a UI change
// can be rendered in the Simulator and looked at before it goes on a device.
//
//     xcrun simctl launch <device> com.backyardballistics.SpudGunGolf -designScene phone-orders
//
// scripts/render-ui.sh runs every scene on an iPhone and an iPad and screenshots each one
// (docs/DESIGN_PROCESS.md). Debug builds only; the data always comes from the bundled sample
// course, never from courses/local.

enum DesignScene: String, CaseIterable {
    case phonePlay = "phone-play"
    case phoneField = "phone-field"
    case phoneKit = "phone-kit"
    case phoneSolo = "phone-solo"
    case phoneEmpty = "phone-empty"
    case phoneReconnect = "phone-reconnect"
    case ipadInvite = "ipad-invite"
    case ipadTeam = "ipad-team"
    /// A joined member's Play screen with three open orders.
    case phoneOrders = "phone-orders"
    /// The newest order as the banner above the Field tab.
    case phoneBanner = "phone-banner"
    /// One order in full: the card and the map.
    case phoneOrderDetail = "phone-order-detail"
    /// Go there: the big pointer and the map.
    case phoneGoTo = "phone-goto"
    /// The spotter card with a round in the air.
    case phoneSpotter = "phone-spotter"
    /// The commander's squad screen: map, orders, roster, hole.
    case ipadCommand = "ipad-command"
    /// The commander part-way through an order: who and what picked, the place on the map.
    case ipadOrderDraft = "ipad-order-draft"

    /// The scene named by `-designScene <name>` on the command line, if any.
    static var current: DesignScene? {
        UserDefaults.standard.string(forKey: "designScene").flatMap(DesignScene.init(rawValue:))
    }

    /// Which device the scene is drawn for. scripts/render-ui.sh renders each on its own device.
    var device: Device { rawValue.hasPrefix("ipad") ? .iPad : .iPhone }
    enum Device { case iPhone, iPad }
}

/// The view a design scene launches into. Loads the fixture, then shows the screen.
struct DesignSceneView: View {
    let scene: DesignScene
    @EnvironmentObject private var command: SquadCommand
    @EnvironmentObject private var membership: SquadMembership
    @EnvironmentObject private var courses: CourseStore
    @EnvironmentObject private var rounds: RoundStore
    @State private var ready = false

    var body: some View {
        Group {
            if ready { screen } else { Color(.systemBackground) }
        }
        .tint(.orange)
        .onAppear {
            guard !ready, let f = DesignFixture.make() else { return }
            courses.loadBundledSample()
            rounds.active = nil
            switch scene.device {
            case .iPad:
                command.loadDesign(f.host, draft: scene == .ipadOrderDraft ? f.draft : nil)
                if let ws = UIApplication.shared.connectedScenes.first as? UIWindowScene {
                    ws.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
                }
            case .iPhone:
                if [.phonePlay, .phoneField, .phoneKit, .phoneSolo].contains(scene) {
                    if scene == .phoneSolo, let course = courses.practiceCourse {
                        rounds.start(course: course, player: "Ben", practice: true)
                    }
                } else {
                    membership.loadDesign(f.phone, fix: f.phoneFix, heading: 20, spotRequest: scene == .phoneSpotter ? f.spotRequest : nil)
                    if scene == .phoneEmpty { for order in membership.orders { membership.ack(order, .done) } }
                    if scene == .phoneReconnect { membership.loadDesignReconnect() }
                }
            }
            ready = true
            Self.markReady(after: scene.device == .iPad ? 4 : 3)
        }
    }

    /// Tells scripts/render-ui.sh the scene is drawn: writes Documents/design-ready once the
    /// screen (and the map's tiles, roughly) has had time to settle.
    private static func markReady(after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("design-ready")
            try? Data().write(to: url)
        }
    }

    @ViewBuilder private var screen: some View {
        switch scene {
        case .phonePlay, .phoneSolo, .phoneOrders, .phoneEmpty, .phoneReconnect:
            RootView()
        case .phoneField, .phoneBanner:
            RootView(selectedTab: .field)
        case .phoneKit:
            RootView(selectedTab: .kit)
        case .phoneOrderDetail:
            NavigationStack { if let o = membership.orders.first { OrderDetailView(order: o) } }
        case .phoneGoTo:
            NavigationStack { if let o = membership.orders.first(where: { $0.kind == .moveTo }) { GoToView(order: o) } }
        case .phoneSpotter:
            NavigationStack { SpotterCard(order: membership.orders.first(where: { $0.kind == .spot })) }
        case .ipadInvite:
            NavigationStack { SquadLobbyView(inviting: true) }
        case .ipadTeam:
            NavigationStack { SquadLobbyView(initialWorkspace: .team) }
        case .ipadCommand, .ipadOrderDraft:
            NavigationStack { CommandSquadView() }
        }
    }
}

/// A made-up squad on the bundled sample course: Ana (the gunner), Ben and Cy, spread around
/// hole 1, with three orders out. Built by running the real `SquadHost`, so what the screens get
/// is what they'd get over the wire.
struct DesignFixture {
    var host: SquadHost
    /// What Ben's phone has received: the welcome, the squad's status and his orders.
    var phone: [GroupMessage.Body]
    var phoneFix: CLLocation
    var spotRequest: SpotRequest?
    var draft: Draft

    struct Draft {
        var targets: Set<MemberID>
        var kind: Order.Kind
        var place: GeoPoint
    }

    static func make(now: Date = Date()) -> DesignFixture? {
        guard let url = Bundle.main.url(forResource: "sample-course", withExtension: "yaml"),
              let data = try? Data(contentsOf: url),
              let course = CourseFile.load(data: data).practiceCourse,
              let hole = course.holes.first, let fp = hole.firingPoints.first else { return nil }
        let flag = hole.flag.position
        var host = SquadHost(squad: Squad(name: "Red"), course: course, practice: true, joinCode: "R7D482")
        var toBen: [GroupMessage.Body] = []
        func deliver(_ out: [Outgoing]) { toBen += out.filter { $0.to == PeerID("ben") }.map(\.body) }

        let people: [(peer: String, name: String, at: GeoPoint)] = [
            ("ana", "Ana", fp),
            ("ben", "Ben", Geo.destination(fp, bearing: 70, distance: 18)),
            ("cy", "Cy", Geo.destination(flag, bearing: 250, distance: 22)),
        ]
        for p in people {
            let hello = Hello(name: p.name, device: UUID(), joinCode: host.joinCode)
            deliver(host.handle(GroupMessage(seq: 1, body: .hello(hello)), from: PeerID(p.peer), now: now))
            let pos = MemberPosition(at: p.at, accuracy: 4, heading: nil, time: now)
            deliver(host.handle(GroupMessage(seq: 2, body: .position(pos)), from: PeerID(p.peer), now: now))
        }
        let ids = Dictionary(uniqueKeysWithValues: host.round.squad.members.map { ($0.name, $0.id) })
        if let ana = ids["Ana"] { deliver(host.setRole(ana, .gunner, now: now)) }
        let ben = ids["Ben"].map { [$0] }
        let side = Geo.destination(flag, bearing: 300, distance: 20)
        deliver(host.sendOrder(.moveTo, text: "Walk out to the tree line, left of the flag.", at: side, to: ben,
                               now: now.addingTimeInterval(-90)))
        deliver(host.sendOrder(.rangeFrom, text: "Range the pole from the tree line.", at: side, to: ben,
                               now: now.addingTimeInterval(-60)))
        deliver(host.sendOrder(.spot, text: "Watch the next round from there.", now: now.addingTimeInterval(-20)))
        // Ana has seen the spot order; the commander's Sent list shows it.
        if let o = host.orders.last {
            _ = host.handle(GroupMessage(seq: 3, body: .orderAck(OrderAck(order: o.id, response: .seen))), from: PeerID("ana"), now: now)
        }
        let benAt = people[1].at
        let request = try? JSONDecoder().decode(SpotRequest.self, from: Data(#"{"hole":1,"mission":1,"round":2}"#.utf8))
        return DesignFixture(
            host: host, phone: toBen,
            phoneFix: CLLocation(coordinate: benAt.coordinate, altitude: 0, horizontalAccuracy: 4, verticalAccuracy: 4, timestamp: now),
            spotRequest: request,
            draft: Draft(targets: Set([ids["Cy"]].compactMap { $0 }), kind: .capture,
                         place: Geo.destination(flag, bearing: 120, distance: 15)))
    }
}
#endif
