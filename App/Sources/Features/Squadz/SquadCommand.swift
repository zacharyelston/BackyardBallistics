import Foundation
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
        let live = Set(host.peers.filter { group?.connections[$0.key] != nil && !closedPeers.contains($0.key) }.values)
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
