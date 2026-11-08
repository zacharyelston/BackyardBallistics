import Foundation
import CoreLocation
import CoreGeo
import GroupKit
import GroupLink

/// A member's phone in v3 Squadz: finds commanders' iPads, joins one with its code, shows the
/// squad's status, and reports this phone's position every few seconds. Phones never show firing data.
@MainActor
final class SquadMembership: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        case connecting(String)
        case joined
        case refused(String)
        case failed(String)
        /// The link dropped after joining.
        case disconnected
    }

    @Published private(set) var found: [GroupBrowser.Found] = []
    @Published private(set) var browseError: String?
    @Published private(set) var state: State = .idle
    @Published private(set) var squadName: String?
    @Published private(set) var welcome: Welcome?
    @Published private(set) var status: SquadStatus?
    /// The round the commander asked members to spot (spotting over the link comes in G5).
    @Published private(set) var spotRequest: SpotRequest?
    @Published private(set) var lastFix: CLLocation?
    @Published private(set) var lastSent: Date?

    /// How often this phone reports its position while joined.
    static let positionInterval: TimeInterval = 3

    private var browser: GroupBrowser?
    private var connection: GroupConnection?
    private var lastTarget: (found: GroupBrowser.Found, code: String, name: String)?
    private let location = CLLocationManager()
    private var timer: Timer?

    /// This phone's own ID, so it rejoins a squad as the same member.
    static var deviceID: UUID {
        let key = "squadDeviceID"
        if let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: key)
        return id
    }

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
    }

    var me: Member? {
        guard let id = welcome?.member else { return nil }
        return (status?.squad ?? welcome?.squad)?.members.first { $0.id == id }
    }

    // MARK: Finding squads

    func startBrowsing() {
        guard browser == nil else { return }
        browseError = nil
        let b = GroupBrowser()
        b.onChange = { [weak self] list in
            self?.found = list.filter { $0.txt[GroupService.Key.role] == nil || $0.txt[GroupService.Key.role] == "squad" }
        }
        b.onFailed = { [weak self] error in self?.browseError = error }
        browser = b
        b.start()
    }

    func stopBrowsing() {
        browser?.stop()
        browser = nil
    }

    // MARK: Joining

    func join(_ squad: GroupBrowser.Found, code: String, name: String) {
        leave(sendBye: false)
        let code = JoinCode.normalized(code)
        lastTarget = (squad, code, name)
        squadName = squad.name
        state = .connecting(squad.name)
        let c = GroupConnection(to: squad.endpoint, joinCode: code)
        c.onState = { [weak self] s in self?.linkChanged(s) }
        c.onMessage = { [weak self] m in self?.receive(m) }
        connection = c
        c.start()
    }

    /// Tries the last squad again with the same code.
    func retry() {
        guard let t = lastTarget else { return }
        join(t.found, code: t.code, name: t.name)
    }

    /// Leaves the squad: tells the commander, then closes the link.
    func leave(sendBye: Bool = true) {
        if sendBye, let c = connection, c.state == .ready {
            c.send(.bye)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { c.cancel() }
        } else {
            connection?.cancel()
        }
        connection = nil
        stopReporting()
        welcome = nil
        status = nil
        spotRequest = nil
        state = .idle
    }

    private func linkChanged(_ s: GroupConnection.State) {
        switch s {
        case .connecting:
            break
        case .ready:
            guard let t = lastTarget else { return }
            connection?.send(.hello(Hello(name: t.name, device: Self.deviceID, joinCode: t.code)))
        case let .failed(reason):
            stopReporting()
            if case .refused = state { return }
            state = welcome == nil ? .failed(reason) : .disconnected
        case .closed:
            stopReporting()
            if state == .joined { state = .disconnected }
        }
    }

    private func receive(_ message: GroupMessage) {
        guard message.protocolVersion == GroupProtocol.version else {
            state = .refused("This squad's iPad runs another version of the app (protocol \(message.protocolVersion)). Update both.")
            connection?.cancel()
            return
        }
        switch message.body {
        case let .welcome(w):
            welcome = w
            squadName = w.squad.name
            state = .joined
            startReporting()
        case let .squadStatus(s):
            status = s
            squadName = s.squad.name
            if s.roundInFlight == nil { spotRequest = nil }
        case let .spotRequest(r):
            spotRequest = r
        case let .refused(reason):
            state = .refused(reason)
            connection?.cancel()
        default:
            break   // lock receipts and the rest come with G5
        }
    }

    // MARK: Position reports

    private func startReporting() {
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        location.startUpdatingLocation()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.positionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPosition() }
        }
    }

    private func stopReporting() {
        timer?.invalidate()
        timer = nil
        location.stopUpdatingLocation()
    }

    private func sendPosition() {
        guard state == .joined, let c = connection, c.state == .ready, let fix = lastFix, fix.horizontalAccuracy > 0 else { return }
        let p = MemberPosition(at: GeoPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                               accuracy: fix.horizontalAccuracy,
                               heading: fix.course >= 0 ? fix.course : nil, time: fix.timestamp)
        c.send(.position(p))
        lastSent = Date()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.lastFix = last }
    }

    var locationDenied: Bool {
        location.authorizationStatus == .denied || location.authorizationStatus == .restricted
    }
}
