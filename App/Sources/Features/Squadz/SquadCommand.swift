import Foundation
import CoreGeo
import CourseKit
import GroupKit
import GroupLink

/// The commander's iPad in v3 Squadz: runs GroupKit's `SquadHost` and advertises it with GroupLink.
///
/// Everything a phone sends goes to `SquadHost.handle`, and whatever it (or a commander action)
/// returns goes back out through `GroupHost.send`. The squad's round is saved after every change,
/// so a relaunch picks the squad up again with the same join code; phones rejoin on their own.
@MainActor
final class SquadCommand: ObservableObject {
    /// What's saved between launches.
    struct Saved: Codable {
        var round: SquadRound
        var joinCode: String
    }

    enum Link: Equatable {
        case off
        case starting
        case listening(port: UInt16)
        case failed(String)
    }

    @Published private(set) var host: SquadHost?
    @Published private(set) var link: Link = .off
    /// Links the transport has closed. `SquadHost` has no message for a dropped phone, so the
    /// roster works out "offline" from this.
    @Published private(set) var closedPeers: Set<PeerID> = []
    #if DEBUG
    /// Design scenes: show every member online (there's no transport to ask).
    var designAllOnline = false
    #endif

    // Drafting an order, one step at a time: who it's for (empty = the whole team), what kind,
    // where (a fresh map tap, for kinds that take a place), then Send. Nothing carries over from
    // the last order: choosing a kind clears the place, and sending clears the whole draft.
    @Published var orderTargets: Set<MemberID> = []
    @Published private(set) var orderKind: Order.Kind?
    @Published var orderPlace: GeoPoint?
    /// The next map tap sets `orderPlace` instead of panning.
    @Published var placingOrder = false
    /// The last order problem (for example no one picked), shown in the Orders panel.
    @Published private(set) var orderProblem: String?

    private var group: GroupHost?
    private let fileURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("squad-round.json")

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            host = SquadHost(round: saved.round, joinCode: saved.joinCode)
        }
    }

    var joinCode: String? { host?.joinCode }
    var isAdvertising: Bool { if case .listening = link { return true } else { return false } }

    /// Starts a new squad on `course` (practice for now) with a fresh join code, and advertises it.
    func start(squadName: String, course: Course) {
        stop()
        let name = squadName.trimmingCharacters(in: .whitespaces).isEmpty ? "Squad" : squadName.trimmingCharacters(in: .whitespaces)
        host = SquadHost(squad: Squad(name: name), course: course, practice: true, joinCode: JoinCode.make())
        save()
        advertise()
    }

    /// Advertises the saved squad again (after a relaunch, or after a failed listener).
    func advertise() {
        guard let host else { return }
        group?.stop()
        closedPeers = []
        link = .starting
        do {
            let g = try GroupHost(name: host.player, joinCode: host.joinCode,
                                  txt: [GroupService.Key.role: "squad", GroupService.Key.course: host.round.course.id])
            g.onReady = { [weak self] port in self?.link = .listening(port: port) }
            g.onFailed = { [weak self] error in self?.link = .failed(error) }
            g.onMessage = { [weak self] message, peer in self?.receive(message, from: peer) }
            g.onPeerClosed = { [weak self] peer in self?.closedPeers.insert(peer) }
            group = g
            g.start()
        } catch {
            link = .failed(String(describing: error))
        }
    }

    /// The app came back to the foreground (after the iPad slept): restart the listener on the same
    /// port now, so phones rejoin without waiting. Members come back as the same members.
    func sceneBecameActive() {
        guard host != nil else { return }
        switch link {
        case .off: return
        case .failed: advertise()
        case .starting, .listening: group?.restart()
        }
    }

    /// Stops advertising and drops every link. The saved round stays, for Resume.
    func stop() {
        group?.stop()
        group = nil
        link = .off
        closedPeers = []
    }

    /// Ends the squad: stops advertising and forgets the saved round.
    func end() {
        stop()
        host = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    // MARK: Roster

    struct RosterLine: Identifiable {
        var member: Member
        var online: Bool
        var position: MemberPosition?
        var id: MemberID { member.id }
    }

    /// Position reports older than this show as stale.
    static let staleAfter: TimeInterval = 15

    var roster: [RosterLine] {
        guard let host else { return [] }
        var live = Set(host.peers.filter { group?.connections[$0.key] != nil && !closedPeers.contains($0.key) }.values)
        #if DEBUG
        if designAllOnline { live = Set(host.peers.values) }
        #endif
        return host.round.squad.members.map {
            RosterLine(member: $0, online: live.contains($0.id), position: host.positions[$0.id])
        }
    }

    /// Theater stations watching this squad.
    var observerCount: Int {
        host?.observers.filter { group?.connections[$0] != nil && !closedPeers.contains($0) }.count ?? 0
    }

    // MARK: Commander actions

    func setRole(_ member: MemberID, _ role: MemberRole) {
        act { $0.setRole(member, role, now: Date()) }
    }

    func remove(_ member: MemberID) {
        act { $0.removeMember(member, now: Date()) }
    }

    // MARK: The hole

    /// Opens the next unfinished hole from the chosen firing point.
    func startNextHole(firingPoint: Int) {
        act { $0.startNextHole(firingPoint: firingPoint, now: Date()) }
    }

    /// The commander's own look downrange. No message from a phone can do this.
    func confirmDownrange() {
        act { $0.confirmDownrange(now: Date()) }
    }

    /// Uses a member's lock for its purpose, after the flag check on this iPad's course.
    func useLock(_ id: UUID) {
        act { $0.useLock(id, now: Date()) }
    }

    /// Fired, on the gunner's behalf: the round is in the air and every member is asked to spot it.
    func fired() {
        act { $0.fired(now: Date()) }
    }

    /// Records the round in flight with a member's call (left/right from their report, or none).
    func commitSpot(from member: MemberID) {
        act { $0.commit(callFrom: member, lateralFrom: nil, now: Date()) }
    }

    func commitLost() {
        act { $0.commitLost(now: Date()) }
    }

    func ceaseFire() {
        act { $0.ceaseFire(now: Date()) }
    }

    func finishHole() {
        act { $0.finish(now: Date()) }
    }

    // MARK: Orders

    /// Step 2: the kind. Clears any place from before; kinds that take a place go straight to
    /// "tap the map".
    func chooseKind(_ kind: Order.Kind?) {
        orderKind = kind
        orderPlace = nil
        placingOrder = kind?.takesPlace ?? false
        orderProblem = nil
    }

    /// Step 3: where, from a map tap.
    func setPlace(_ p: GeoPoint) {
        orderPlace = p
        placingOrder = false
    }

    /// Ready to send: a kind, a place if the kind needs one, and a note for a Note.
    func canSend(text: String) -> Bool {
        guard let k = orderKind else { return false }
        if k.takesPlace && orderPlace == nil { return false }
        if k == .note && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return true
    }

    /// Step 4: sends the draft to the picked members, or the whole team when none are picked,
    /// then clears the draft so the next order starts fresh.
    @discardableResult
    func sendOrder(text: String) -> Bool {
        guard let kind = orderKind, canSend(text: text) else { return false }
        let before = host?.orders.count ?? 0
        let to = orderTargets.isEmpty ? nil : Array(orderTargets)
        act { $0.sendOrder(kind, text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                           at: kind.takesPlace ? orderPlace : nil, to: to, now: Date()) }
        let sent = (host?.orders.count ?? 0) > before
        if sent {
            clearOrderDraft()
        } else {
            orderProblem = host?.lastProblem ?? "The order wasn't sent."
        }
        return sent
    }

    func clearOrderDraft() {
        orderTargets = []
        orderKind = nil
        orderPlace = nil
        placingOrder = false
        orderProblem = nil
    }

    /// Members each unfinished order with a place is for, with where they are now: the pointer
    /// lines on the commander's map.
    var orderPointers: [SiteMapRay] {
        guard let host else { return [] }
        var rays: [SiteMapRay] = []
        for order in host.orders.suffix(20) {
            guard let at = order.at else { continue }
            for m in host.recipients(of: order) {
                let answer = host.acks[order.id]?[m.id]
                guard answer != .done, answer != .cannot, let p = host.positions[m.id] else { continue }
                rays.append(SiteMapRay(from: p.at, to: at))
            }
        }
        return rays
    }

    func toggleTarget(_ member: MemberID) {
        if orderTargets.contains(member) { orderTargets.remove(member) } else { orderTargets.insert(member) }
    }

    /// Runs a commander action and sends what it returns.
    func act(_ action: (inout SquadHost) -> [Outgoing]) {
        guard var h = host else { return }
        let out = action(&h)
        host = h
        group?.send(out)
        save()
    }

    // MARK: Internals

    private func receive(_ message: GroupMessage, from peer: PeerID) {
        guard var h = host else { return }
        closedPeers.remove(peer)
        let out = h.handle(message, from: peer, now: Date())
        host = h
        group?.send(out)
        save()
    }

    private func save() {
        guard let host, let data = try? JSONEncoder().encode(Saved(round: host.round, joinCode: host.joinCode)) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

#if DEBUG
extension SquadCommand {
    /// Design scenes only: commands `host` as if it were advertising with every member online,
    /// optionally part-way through an order. Nothing is saved or sent. See DesignScenes.swift.
    func loadDesign(_ host: SquadHost, draft: DesignFixture.Draft?) {
        self.host = host
        link = .listening(port: 7400)
        designAllOnline = true
        if let draft {
            orderTargets = draft.targets
            chooseKind(draft.kind)
            setPlace(draft.place)
        }
    }
}
#endif
