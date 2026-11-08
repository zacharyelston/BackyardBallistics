import Foundation
import CoreLocation
import UIKit
import UserNotifications
import CoreGeo
import RangingKit
import GroupKit
import GroupLink

/// A member's phone in v3 Squadz: finds commanders' iPads, joins one with its code, shows the
/// squad's status, and reports this phone's position every few seconds. Phones never show firing data.
@MainActor
final class SquadMembership: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum State: Equatable {
        case idle
        /// Finding the squad and saying hello.
        case connecting(String)
        case joined
        /// The link dropped (the iPad slept, Wi-Fi blinked); `GroupClient` is rejoining on its own.
        case reconnecting(String)
        case refused(String)
        case failed(String)
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
    /// Which way the phone points, degrees from true north (magnetic if true isn't available), for
    /// the order pointer. Nil until the compass reports.
    @Published private(set) var heading: Double?
    /// Join squad is on screen (it lists the orders itself, so the banner stays out of the way).
    @Published var showingJoinScreen = false
    @Published private(set) var lastSent: Date?
    /// Locks this phone sent to the commander, newest last, with what the commander did with each.
    @Published private(set) var sentLocks: [SentLock] = []
    /// The squad leader's orders for this member that aren't finished (done or can't), newest last.
    @Published private(set) var orders: [Order] = []
    /// This member's answers, by order.
    @Published private(set) var answers: [UUID: OrderAck.Response] = [:]
    /// Orders answered done or can't, so a resend after a rejoin doesn't bring them back.
    private var finishedOrders: Set<UUID> = []

    struct SentLock: Identifiable, Equatable {
        var id: UUID
        var purpose: LockPurpose
        var date: Date
        var receipt: LockReceipt?
    }

    /// How often this phone reports its position while joined.
    static let positionInterval: TimeInterval = 3

    private var browser: GroupBrowser?
    private var client: GroupClient?
    private var lastTarget: (squad: String, code: String, name: String)?
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
        location.distanceFilter = kCLDistanceFilterNone
        location.pausesLocationUpdatesAutomatically = false
        location.activityType = .fitness
    }

    var me: Member? {
        guard let id = welcome?.member else { return nil }
        return (status?.squad ?? welcome?.squad)?.members.first { $0.id == id }
    }

    /// In a squad, or trying to get back into one.
    var isInSquad: Bool {
        switch state {
        case .joined, .reconnecting: return true
        default: return false
        }
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

    /// Joins a squad by its name. `GroupClient` keeps the link up from here on: after any drop it
    /// finds the squad again and rejoins as the same member.
    func join(_ squad: GroupBrowser.Found, code: String, name: String) {
        join(squadName: squad.name, code: code, name: name)
    }

    private func join(squadName name: String, code: String, name player: String) {
        leave()
        let code = JoinCode.normalized(code)
        lastTarget = (name, code, player)
        squadName = name
        state = .connecting(name)
        let c = GroupClient(squadName: name, joinCode: code, hello: Hello(name: player, device: Self.deviceID, joinCode: code))
        c.onStatus = { [weak self] s in self?.clientChanged(s) }
        c.onMessage = { [weak self] m in self?.receive(m) }
        client = c
        c.start()
    }

    /// Tries again now: straight away if the client is still trying, or from scratch after it gave up.
    func retry() {
        if let c = client, !Self.isStopped(c.status) {
            c.retryNow()
        } else if let t = lastTarget {
            join(squadName: t.squad, code: t.code, name: t.name)
        }
    }

    private static func isStopped(_ s: GroupClient.Status) -> Bool {
        if case .stopped = s { return true } else { return false }
    }

    /// The app came back to the foreground: don't wait out the backoff.
    func sceneBecameActive() {
        guard let c = client, c.status != .connected else { return }
        c.retryNow()
    }

    /// Leaves the squad: says bye (if linked) and stops rejoining.
    func leave() {
        let c = client
        client = nil
        c?.onStatus = nil
        c?.onMessage = nil
        c?.stop()
        stopReporting()
        welcome = nil
        status = nil
        spotRequest = nil
        sentLocks = []
        orders = []
        answers = [:]
        finishedOrders = []
        state = .idle
    }

    private func clientChanged(_ s: GroupClient.Status) {
        let name = squadName ?? "the squad"
        switch s {
        case .searching, .connecting:
            if welcome == nil { state = .connecting(name) }
        case .connected:
            // The hello is out; the welcome (or a refusal) follows. A rejoin keeps showing the squad.
            if welcome != nil { state = .joined }
        case let .reconnecting(why):
            state = welcome == nil ? .connecting(name) : .reconnecting(why)
        case let .stopped(why):
            stopReporting()
            if case .refused = state { return }
            state = why == "Left" ? .idle : .failed(why)
        }
    }

    private func receive(_ message: GroupMessage) {
        guard message.protocolVersion == GroupProtocol.version else {
            state = .refused("This squad's iPad runs another version of the app (protocol \(message.protocolVersion)). Update both.")
            client?.stop()
            return
        }
        switch message.body {
        case let .welcome(w):
            welcome = w
            squadName = w.squad.name
            state = .joined
            startReporting()
            Self.askForNotifications()
        case let .squadStatus(s):
            status = s
            squadName = s.squad.name
            if s.roundInFlight == nil { spotRequest = nil }
        case let .spotRequest(r):
            spotRequest = r
        case let .refused(reason):
            state = .refused(reason)   // GroupClient stops on a refusal
        case let .lockReceipt(r):
            if let i = sentLocks.firstIndex(where: { $0.id == r.lock }) { sentLocks[i].receipt = r }
        case let .order(o):
            received(o)
        default:
            break   // observer-only messages and the rest aren't for phones
        }
    }

    // MARK: Orders

    /// Answers an order. Done and can't take it off this phone's list; seen keeps it there.
    func ack(_ order: Order, _ response: OrderAck.Response) {
        answers[order.id] = response
        client?.send(.orderAck(OrderAck(order: order.id, response: response)))
        if response != .seen {
            finishedOrders.insert(order.id)
            orders.removeAll { $0.id == order.id }
        }
    }

    private func received(_ o: Order) {
        guard !finishedOrders.contains(o.id) else { return }
        if let i = orders.firstIndex(where: { $0.id == o.id }) { orders[i] = o; return }   // a resend after a rejoin
        orders.append(o)
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        if UIApplication.shared.applicationState != .active { Self.notify(o, squad: squadName) }
    }

    /// Asks once, on the first join, so new orders can reach a locked phone.
    private static func askForNotifications() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private static func notify(_ o: Order, squad: String?) {
        let content = UNMutableNotificationContent()
        content.title = "\(squad ?? "Squad"): \(o.kind.title)"
        content.body = o.text.isEmpty ? "New order from the squad leader." : o.text
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: o.id.uuidString, content: content, trigger: nil))
    }

    /// Bearing (degrees from north) and distance (metres) from this phone's latest fix to an order's place.
    func pointer(to order: Order) -> (bearing: Double, distance: Double)? {
        guard let at = order.at, let fix = lastFix else { return nil }
        let here = GeoPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        return (Geo.bearing(from: here, to: at), Geo.distance(here, at))
    }

    /// Distance and compass direction from this phone's latest fix to an order's place, if both are known.
    func directions(to order: Order) -> String? {
        guard let at = order.at, let fix = lastFix else { return nil }
        let here = GeoPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude)
        let d = Geo.distance(here, at)
        let b = Geo.bearing(from: here, to: at)
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let compass = points[Int((b + 22.5) / 45) % 8]
        return String(format: "%.0f m %@ (%03.0f°)", d, compass, b)
    }

    // MARK: Locks

    /// Sends a raw reticle lock to the commander's iPad, which checks it against its own course flag
    /// and uses it for `purpose`. The phone shows what the commander did with it, not firing data.
    /// Nil when not linked to a squad.
    @discardableResult
    func sendLock(_ lock: ReticleLock, purpose: LockPurpose) -> UUID? {
        guard state == .joined, let c = client, c.status == .connected else { return nil }
        let report = LockReport(purpose: purpose, lock: lock)
        c.send(.lock(report))
        sentLocks.append(SentLock(id: report.id, purpose: purpose, date: Date()))
        if sentLocks.count > 20 { sentLocks.removeFirst(sentLocks.count - 20) }
        return report.id
    }

    func sentLock(_ id: UUID?) -> SentLock? {
        guard let id else { return nil }
        return sentLocks.first { $0.id == id }
    }

    // MARK: Position reports

    /// Reports keep going with the screen locked or another app in front, while in a squad (the
    /// background location mode; iOS shows the location indicator). They stop on leaving.
    private func startReporting() {
        guard timer == nil else { return }
        if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
        location.allowsBackgroundLocationUpdates = true
        location.showsBackgroundLocationIndicator = true
        location.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { location.startUpdatingHeading() }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.positionInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sendPosition() }
        }
    }

    private func stopReporting() {
        timer?.invalidate()
        timer = nil
        location.stopUpdatingLocation()
        location.stopUpdatingHeading()
        location.allowsBackgroundLocationUpdates = false
    }

    private func sendPosition() {
        // Only while linked: GroupClient drops sends otherwise, but don't count them as sent.
        guard state == .joined, let c = client, c.status == .connected, let fix = lastFix, fix.horizontalAccuracy > 0 else { return }
        let p = MemberPosition(at: GeoPoint(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude),
                               accuracy: fix.horizontalAccuracy,
                               heading: fix.course >= 0 ? fix.course : nil, time: fix.timestamp)
        c.send(.position(p))
        lastSent = Date()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in self.heading = h }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in
            self.lastFix = last
            // In the background the timer may not fire; location updates keep the app running, so
            // report from here too, no more often than the interval.
            if self.lastSent.map({ Date().timeIntervalSince($0) >= Self.positionInterval }) ?? true { self.sendPosition() }
        }
    }

    var locationDenied: Bool {
        location.authorizationStatus == .denied || location.authorizationStatus == .restricted
    }
}
