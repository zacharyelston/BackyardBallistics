import Foundation

/// The seam between the game and the radio. The app's Network.framework transport and the
/// in-memory loopback both implement it; nothing above it knows which is in use.
public protocol GroupTransport: AnyObject {
    var device: DeviceID { get }
    /// Called with every envelope that arrives for this device.
    var onReceive: ((Envelope) -> Void)? { get set }
    func send(_ message: GroupMessage, to: DeviceID)
}

public extension GroupTransport {
    func send(_ outbound: [Outbound]) { for o in outbound { send(o.message, to: o.to) } }
}

/// An in-memory network for tests and the Simulator. Messages are JSON-encoded on send and decoded
/// on delivery, so everything that crosses it is proven Codable. Delivery happens only in `deliver()`,
/// in order, and links can be cut to simulate a phone walking out of range.
public final class LoopbackNetwork {
    private var endpoints: [DeviceID: LoopbackTransport] = [:]
    private var queue: [(from: DeviceID, to: DeviceID, data: Data)] = []
    private var cut: Set<Set<DeviceID>> = []
    public private(set) var dropped = 0
    public private(set) var delivered = 0

    public init() {}

    public func endpoint(_ device: DeviceID = DeviceID()) -> LoopbackTransport {
        if let e = endpoints[device] { return e }
        let e = LoopbackTransport(device: device, network: self)
        endpoints[device] = e
        return e
    }

    public func cutLink(_ a: DeviceID, _ b: DeviceID) { cut.insert([a, b]) }
    public func healLink(_ a: DeviceID, _ b: DeviceID) { cut.remove([a, b]) }

    func enqueue(_ data: Data, from: DeviceID, to: DeviceID) {
        if cut.contains([from, to]) || endpoints[to] == nil { dropped += 1; return }
        queue.append((from, to, data))
    }

    /// Delivers queued messages, including any sent while delivering, until the queue is empty.
    public func deliver(maxMessages: Int = 100_000) {
        var n = 0
        while !queue.isEmpty && n < maxMessages {
            let m = queue.removeFirst()
            n += 1
            guard !cut.contains([m.from, m.to]), let e = endpoints[m.to],
                  let env = try? JSONDecoder().decode(Envelope.self, from: m.data) else { dropped += 1; continue }
            guard env.protocolVersion == GroupRules.protocolVersion else { dropped += 1; continue }
            delivered += 1
            e.onReceive?(env)
        }
    }
}

public final class LoopbackTransport: GroupTransport {
    public let device: DeviceID
    public var onReceive: ((Envelope) -> Void)?
    private unowned let network: LoopbackNetwork
    private var seq = 0

    init(device: DeviceID, network: LoopbackNetwork) {
        self.device = device
        self.network = network
    }

    public func send(_ message: GroupMessage, to: DeviceID) {
        seq += 1
        guard let data = try? JSONEncoder().encode(Envelope(sender: device, seq: seq, body: message)) else { return }
        network.enqueue(data, from: device, to: to)
    }
}
