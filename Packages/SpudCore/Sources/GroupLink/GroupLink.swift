import Foundation
import Network
import Security
import CryptoKit
import GroupKit

// v3 Squadz over the local network (G4): Bonjour to find a commander's iPad, TCP with TLS keyed
// from the join code, and GroupKit's length-prefixed JSON frames. Works on home Wi-Fi and, with
// peer-to-peer Wi-Fi, with no router. The hosts' logic stays in GroupKit; this only moves bytes.

public enum GroupService {
    /// The Bonjour service every squad host advertises.
    public static let type = "_spudgolf._tcp"

    /// TXT record keys.
    public enum Key {
        public static let role = "role"          // "squad" (later "match")
        public static let protocolVersion = "v"
        public static let course = "course"
    }
}

public extension NWParameters {
    /// TCP with TLS keyed from the join code (a pre-shared key), so only people who have the code
    /// can connect, and nothing travels in the clear. Peer-to-peer Wi-Fi is allowed.
    static func groupLink(joinCode: String) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.noDelay = true

        let tls = NWProtocolTLS.Options()
        let key = SymmetricKey(data: Data(JoinCode.normalized(joinCode).utf8))
        let psk = Data(HMAC<SHA256>.authenticationCode(for: Data("SpudGunGolf group link".utf8), using: key))
        let identity = Data("SpudGunGolf".utf8)
        psk.withUnsafeBytes { pskBytes in
            identity.withUnsafeBytes { idBytes in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                                                        DispatchData(bytes: pskBytes) as __DispatchData,
                                                        DispatchData(bytes: idBytes) as __DispatchData)
            }
        }
        sec_protocol_options_append_tls_ciphersuite(tls.securityProtocolOptions,
                                                    tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)

        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// One link: a phone's (or a Theater station's) connection to a commander, or the commander's
/// side of it. Everything happens on `queue`, including the callbacks.
public final class GroupConnection {
    public enum State: Equatable, Sendable {
        case connecting
        case ready
        case failed(String)
        case closed
    }

    public let peer: PeerID
    public private(set) var state: State = .connecting
    public var onMessage: ((GroupMessage) -> Void)?
    public var onState: ((State) -> Void)?

    let connection: NWConnection
    private let queue: DispatchQueue
    private var reader = GroupWire.FrameReader()
    private var seq = 0

    init(_ connection: NWConnection, peer: PeerID, queue: DispatchQueue) {
        self.connection = connection
        self.peer = peer
        self.queue = queue
    }

    /// Connects to a commander found by `GroupBrowser`, or to a host and port.
    public convenience init(to endpoint: NWEndpoint, joinCode: String, queue: DispatchQueue = .main) {
        self.init(NWConnection(to: endpoint, using: .groupLink(joinCode: joinCode)),
                  peer: PeerID("host"), queue: queue)
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready:
                self.set(.ready)
                self.receive()
            case let .failed(error):
                self.set(.failed(Self.describe(error)))
            case let .waiting(error):
                // TLS refusing the key shows up here: a wrong join code.
                self.set(.failed(Self.describe(error)))
                self.connection.cancel()
            case .cancelled:
                self.set(.closed)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ body: GroupMessage.Body) {
        seq += 1
        guard let frame = try? GroupWire.encode(GroupMessage(seq: seq, body: body)) else { return }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    public func cancel() {
        connection.cancel()
    }

    private func set(_ s: State) {
        guard s != state else { return }
        state = s
        onState?(s)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for m in try self.reader.append(data) { self.onMessage?(m) }
                } catch {
                    self.set(.failed("Bad data from \(self.peer): \(error)"))
                    self.connection.cancel()
                    return
                }
            }
            if isComplete {
                self.connection.cancel()
            } else if let error {
                self.set(.failed(Self.describe(error)))
            } else {
                self.receive()
            }
        }
    }

    static func describe(_ error: NWError) -> String {
        // With a pre-shared key, a TLS handshake failure means the two sides hold different keys:
        // the codes don't match (the client usually sees -9820, bad MAC).
        if case let .tls(status) = error { return "Couldn't connect: check the join code (TLS \(status))." }
        return String(describing: error)
    }
}

/// The commander's side: advertises the squad over Bonjour and accepts connections. Feed what it
/// receives to `SquadHost.handle`, and send what that returns with `send`.
///
/// If the listener fails (the iPad slept, the network changed), it starts a new one with the same
/// name, code and port after a short pause; phones reconnect on their own (`GroupClient`).
public final class GroupHost {
    public var onMessage: ((GroupMessage, PeerID) -> Void)?
    public var onPeerClosed: ((PeerID) -> Void)?
    public var onReady: ((UInt16) -> Void)?
    public var onFailed: ((String) -> Void)?
    public private(set) var connections: [PeerID: GroupConnection] = [:]
    public var port: UInt16? { listener?.port?.rawValue ?? lastPort }

    private var listener: NWListener?
    private var lastPort: UInt16?
    private var stopped = false
    private let name: String
    private let joinCode: String
    private let txt: [String: String]
    private let advertise: Bool
    private let queue: DispatchQueue
    /// Seconds before a failed listener is started again.
    public var restartDelay: TimeInterval = 1.5

    /// - Parameter advertise: off in tests, which connect to the port directly.
    public init(name: String, joinCode: String, txt: [String: String] = [:], advertise: Bool = true,
                queue: DispatchQueue = .main) throws {
        self.name = name
        self.joinCode = joinCode
        self.txt = txt
        self.advertise = advertise
        self.queue = queue
        listener = try makeListener(port: nil)
    }

    private func makeListener(port: UInt16?) throws -> NWListener {
        let params = NWParameters.groupLink(joinCode: joinCode)
        let l: NWListener
        if let port, let p = NWEndpoint.Port(rawValue: port) {
            params.allowLocalEndpointReuse = true
            l = try NWListener(using: params, on: p)
        } else {
            l = try NWListener(using: params)
        }
        if advertise {
            var record = NWTXTRecord()
            record[GroupService.Key.protocolVersion] = String(GroupProtocol.version)
            for (k, v) in txt { record[k] = v }
            l.service = NWListener.Service(name: name, type: GroupService.type, txtRecord: record)
        }
        return l
    }

    public func start() {
        stopped = false
        guard let listener else { return }
        listener.stateUpdateHandler = { [weak self, weak listener] s in
            guard let self, let listener, listener === self.listener else { return }
            switch s {
            case .ready:
                if let p = listener.port?.rawValue { self.lastPort = p; self.onReady?(p) }
            case let .failed(e):
                self.onFailed?(String(describing: e))
                self.restartSoon()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
        listener.start(queue: queue)
    }

    /// Starts a fresh listener now, for example when the app comes back to the foreground.
    public func restart() {
        guard !stopped else { return }
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = (try? makeListener(port: lastPort)) ?? (try? makeListener(port: nil))
        start()
    }

    private func restartSoon() {
        queue.asyncAfter(deadline: .now() + restartDelay) { [weak self] in self?.restart() }
    }

    private func accept(_ nw: NWConnection) {
        let peer = PeerID(UUID().uuidString)
        let c = GroupConnection(nw, peer: peer, queue: queue)
        c.onMessage = { [weak self] m in self?.onMessage?(m, peer) }
        c.onState = { [weak self] s in
            switch s {
            case .failed, .closed:
                guard self?.connections[peer] != nil else { return }
                self?.connections[peer] = nil
                self?.onPeerClosed?(peer)
            default: break
            }
        }
        connections[peer] = c
        c.start()
    }

    public func send(_ outgoing: [Outgoing]) {
        for o in outgoing { connections[o.to]?.send(o.body) }
    }

    public func stop() {
        stopped = true
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        for c in connections.values { c.cancel() }
        connections = [:]
    }
}

/// A phone's or Theater station's link to one squad, by its Bonjour name, that keeps itself up:
/// it finds the squad, connects, says hello, and after any drop (the iPad slept, Wi-Fi blinked)
/// finds it again and rejoins. Rejoining with the same device ID keeps the same member. It stops
/// only when told to, or when the code is wrong or the squad refuses it.
public final class GroupClient {
    public enum Status: Equatable, Sendable {
        case searching
        case connecting
        case connected
        /// Lost the link; trying again.
        case reconnecting(String)
        /// Won't retry: a wrong code, a refusal, or an incompatible version.
        case stopped(String)
    }

    public private(set) var status: Status = .searching
    public var onStatus: ((Status) -> Void)?
    public var onMessage: ((GroupMessage) -> Void)?

    public let squadName: String
    private let joinCode: String
    private let hello: Hello
    private let queue: DispatchQueue
    private var browser: GroupBrowser?
    private var connection: GroupConnection?
    private var running = false
    private var attempt = 0
    /// Seconds between attempts, growing to `maxDelay`.
    public var baseDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 8
    /// For tests and fixed hosts: connect here instead of browsing for `squadName`.
    public var fixedEndpoint: NWEndpoint?

    public init(squadName: String, joinCode: String, hello: Hello, queue: DispatchQueue = .main) {
        self.squadName = squadName
        self.joinCode = joinCode
        self.hello = hello
        self.queue = queue
    }

    public func start() {
        guard !running else { return }
        running = true
        attempt = 0
        find()
    }

    public func send(_ body: GroupMessage.Body) {
        guard status == .connected else { return }
        connection?.send(body)
    }

    /// Leaves: says bye and stops reconnecting.
    public func stop() {
        guard running else { return }
        if status == .connected { connection?.send(.bye) }
        running = false
        tearDown()
        set(.stopped("Left"))
    }

    /// Try again now (for example when the app returns to the foreground).
    public func retryNow() {
        guard running, status != .connected else { return }
        attempt = 0
        tearDown()
        find()
    }

    private func find() {
        guard running else { return }
        if let fixedEndpoint { return connect(to: fixedEndpoint) }
        set(attempt == 0 ? .searching : status)
        let b = GroupBrowser(queue: queue)
        browser = b
        b.onChange = { [weak self, weak b] found in
            guard let self, let b, b === self.browser, self.connection == nil else { return }
            guard let f = found.first(where: { $0.name == self.squadName }) else { return }
            guard f.isCompatible else {
                return self.giveUp("\(self.squadName) runs protocol v\(f.protocolVersion.map(String.init) ?? "?"); this app speaks v\(GroupProtocol.version). Update both.")
            }
            b.stop()
            self.browser = nil
            self.connect(to: f.endpoint)
        }
        b.start()
    }

    private func connect(to endpoint: NWEndpoint) {
        guard running else { return }
        if attempt == 0 { set(.connecting) }
        let c = GroupConnection(to: endpoint, joinCode: joinCode, queue: queue)
        connection = c
        c.onState = { [weak self, weak c] s in
            guard let self, let c, c === self.connection else { return }
            switch s {
            case .ready:
                self.attempt = 0
                c.send(.hello(self.hello))
                self.set(.connected)
            case let .failed(why):
                if why.contains("join code") { return self.giveUp(why) }
                self.dropped(why)
            case .closed:
                self.dropped("Connection closed")
            case .connecting:
                break
            }
        }
        c.onMessage = { [weak self] m in
            guard let self else { return }
            if case let .refused(why) = m.body { self.giveUp(why) }
            self.onMessage?(m)
        }
        c.start()
    }

    private func dropped(_ why: String) {
        guard running else { return }
        tearDown()
        attempt += 1
        set(.reconnecting(why))
        let delay = min(maxDelay, baseDelay * pow(2, Double(min(attempt - 1, 4))))
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.find() }
    }

    private func giveUp(_ why: String) {
        running = false
        tearDown()
        set(.stopped(why))
    }

    private func tearDown() {
        browser?.stop()
        browser = nil
        let c = connection
        connection = nil
        c?.onState = nil
        c?.onMessage = nil
        c?.cancel()
    }

    private func set(_ s: Status) {
        guard s != status else { return }
        status = s
        onStatus?(s)
    }
}

/// Finds commanders' iPads on the local network.
public final class GroupBrowser {
    public struct Found: Hashable, Identifiable, Sendable {
        public var name: String
        public var endpoint: NWEndpoint
        public var txt: [String: String]
        public var id: String { name }
        public var protocolVersion: Int? { txt[GroupService.Key.protocolVersion].flatMap(Int.init) }
        public var isCompatible: Bool { protocolVersion == GroupProtocol.version }
    }

    public var onChange: (([Found]) -> Void)?
    public var onFailed: ((String) -> Void)?
    private let browser: NWBrowser
    private let queue: DispatchQueue

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
        let p = NWParameters()
        p.includePeerToPeer = true
        browser = NWBrowser(for: .bonjourWithTXTRecord(type: GroupService.type, domain: nil), using: p)
    }

    public func start() {
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { r -> Found? in
                guard case let .service(name, _, _, _) = r.endpoint else { return nil }
                var txt: [String: String] = [:]
                if case let .bonjour(record) = r.metadata { txt = record.dictionary }
                return Found(name: name, endpoint: r.endpoint, txt: txt)
            }
            self?.onChange?(found.sorted { $0.name < $1.name })
        }
        browser.stateUpdateHandler = { [weak self] s in
            if case let .failed(e) = s { self?.onFailed?(String(describing: e)) }
        }
        browser.start(queue: queue)
    }

    public func stop() { browser.cancel() }
}
