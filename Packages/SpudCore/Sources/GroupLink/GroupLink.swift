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

/// Six characters, without the ones people misread (0/O, 1/I/L).
public enum JoinCode {
    static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    public static func make() -> String {
        var g = SystemRandomNumberGenerator()
        return String((0..<6).map { _ in alphabet.randomElement(using: &g)! })
    }
    public static func normalized(_ code: String) -> String {
        code.uppercased().filter { !$0.isWhitespace && $0 != "-" }
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
        if case let .tls(status) = error, status == errSSLHandshakeFail || status == errSSLBadRecordMac || status == -9806 {
            return "Couldn't connect: check the join code."
        }
        return String(describing: error)
    }
}

/// The commander's side: advertises the squad over Bonjour and accepts connections. Feed what it
/// receives to `SquadHost.handle`, and send what that returns with `send`.
public final class GroupHost {
    public var onMessage: ((GroupMessage, PeerID) -> Void)?
    public var onPeerClosed: ((PeerID) -> Void)?
    public var onReady: ((UInt16) -> Void)?
    public var onFailed: ((String) -> Void)?
    public private(set) var connections: [PeerID: GroupConnection] = [:]
    public var port: UInt16? { listener.port?.rawValue }

    private let listener: NWListener
    private let queue: DispatchQueue

    /// - Parameter advertise: off in tests, which connect to the port directly.
    public init(name: String, joinCode: String, txt: [String: String] = [:], advertise: Bool = true,
                queue: DispatchQueue = .main) throws {
        self.queue = queue
        listener = try NWListener(using: .groupLink(joinCode: joinCode))
        if advertise {
            var record = NWTXTRecord()
            record[GroupService.Key.protocolVersion] = String(GroupProtocol.version)
            for (k, v) in txt { record[k] = v }
            listener.service = NWListener.Service(name: name, type: GroupService.type, txtRecord: record)
        }
    }

    public func start() {
        listener.stateUpdateHandler = { [weak self] s in
            guard let self else { return }
            switch s {
            case .ready: if let p = self.listener.port?.rawValue { self.onReady?(p) }
            case let .failed(e): self.onFailed?(String(describing: e))
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] nw in
            guard let self else { return }
            let peer = PeerID(UUID().uuidString)
            let c = GroupConnection(nw, peer: peer, queue: self.queue)
            c.onMessage = { [weak self] m in self?.onMessage?(m, peer) }
            c.onState = { [weak self] s in
                switch s {
                case .failed, .closed:
                    self?.connections[peer] = nil
                    self?.onPeerClosed?(peer)
                default: break
                }
            }
            self.connections[peer] = c
            c.start()
        }
        listener.start(queue: queue)
    }

    public func send(_ outgoing: [Outgoing]) {
        for o in outgoing { connections[o.to]?.send(o.body) }
    }

    public func stop() {
        listener.cancel()
        for c in connections.values { c.cancel() }
        connections = [:]
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
