import Foundation

/// An in-memory network for tests and the Simulator. Every message is framed and parsed with
/// `GroupWire`, exactly as it would be on Wi-Fi, so anything that can't cross the wire fails here too.
///
/// Delivery is first in, first out, and only when `run` is called. A node that is `down` sends and
/// receives nothing (a dropped link).
public final class LoopbackNetwork {
    public typealias Handler = (GroupMessage, PeerID) -> [Outgoing]

    public struct Delivery: Equatable {
        public var from: PeerID
        public var to: PeerID
        public var message: GroupMessage
    }

    private var handlers: [PeerID: Handler] = [:]
    private var readers: [PeerID: GroupWire.FrameReader] = [:]
    private var queue: [(from: PeerID, to: PeerID, frame: Data)] = []
    private var seq: [PeerID: Int] = [:]
    public var down: Set<PeerID> = []
    /// Everything delivered, in order.
    public private(set) var log: [Delivery] = []

    public init() {}

    public func add(_ peer: PeerID, handler: @escaping Handler) {
        handlers[peer] = handler
        readers[peer] = GroupWire.FrameReader()
    }

    public func send(from: PeerID, _ outgoing: [Outgoing]) {
        guard !down.contains(from) else { return }
        for o in outgoing {
            let n = (seq[from] ?? 0) + 1
            seq[from] = n
            // Every body in GroupKit encodes; a failure here is a bug worth crashing a test on.
            let frame = try! GroupWire.encode(GroupMessage(seq: n, body: o.body))
            queue.append((from, o.to, frame))
        }
    }

    /// Sends raw bytes as if from `from`, for fuzzing the parser and the hosts.
    public func sendRaw(from: PeerID, to: PeerID, _ bytes: Data) {
        queue.append((from, to, bytes))
    }

    /// Delivers until nothing is left to deliver. Returns the number of messages delivered.
    @discardableResult
    public func run(maxDeliveries: Int = 100_000) -> Int {
        var delivered = 0
        while !queue.isEmpty && delivered < maxDeliveries {
            let (from, to, frame) = queue.removeFirst()
            guard !down.contains(to), !down.contains(from), let handler = handlers[to] else { continue }
            let messages: [GroupMessage]
            do {
                messages = try readers[to]!.append(frame)
            } catch {
                readers[to] = GroupWire.FrameReader()   // a bad frame closes the link: start clean
                continue
            }
            for m in messages {
                delivered += 1
                log.append(Delivery(from: from, to: to, message: m))
                send(from: to, handler(m, from))
            }
        }
        return delivered
    }
}
