import Foundation
import CryptoKit
import CourseKit

/// Length-prefixed JSON frames: a 4-byte big-endian length, then a `GroupMessage` as JSON.
/// The same framing runs over TCP (milestone G4) and the loopback.
public enum GroupWire {
    /// Larger frames are refused. Capture bundles (photos, meshes) go on their own connection.
    public static let maxFrameBytes = 1 << 20

    public enum WireError: Error, Equatable {
        case frameTooLarge(Int)
        case undecodable(String)
    }

    public static func encode(_ message: GroupMessage) throws -> Data {
        let json = try encoder.encode(message)
        guard json.count <= maxFrameBytes else { throw WireError.frameTooLarge(json.count) }
        var length = UInt32(json.count).bigEndian
        var frame = Data(bytes: &length, count: 4)
        frame.append(json)
        return frame
    }

    /// Accumulates bytes as they arrive and returns whole messages.
    public struct FrameReader {
        private var buffer = Data()
        public init() {}

        public mutating func append(_ bytes: Data) throws -> [GroupMessage] {
            buffer.append(bytes)
            var out: [GroupMessage] = []
            while buffer.count >= 4 {
                let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length <= maxFrameBytes else { buffer.removeAll(); throw WireError.frameTooLarge(length) }
                guard buffer.count >= 4 + length else { break }
                let json = buffer.dropFirst(4).prefix(length)
                buffer = Data(buffer.dropFirst(4 + length))
                do {
                    out.append(try decoder.decode(GroupMessage.self, from: Data(json)))
                } catch {
                    throw WireError.undecodable(String(describing: error))
                }
            }
            return out
        }
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = .sortedKeys
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }()
}

/// Devices check that they loaded the same course.
public enum CourseFingerprint {
    public static func hash(_ course: Course) -> String {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return sha256Hex((try? e.encode(course)) ?? Data())
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
