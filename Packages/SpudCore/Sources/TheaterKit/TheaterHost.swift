import Foundation
import CoreGeo
import CourseKit
import FieldKit
import GroupKit

/// The Theater host's door for phones (path 2 in GroupKit's FieldNotes.swift): a phone joins with
/// the Theater's code as a `contributor` and sends fields, notes and files. Fields are registered in
/// the field list, notes and files are saved under their field's folder. Pure apart from the files
/// it writes under `store.root`; `handle` returns the messages to send.
///
///   <field>/notes/<note-id>.json (+ <note-id>.jpg)       notes
///   <field>/captures/<group-id>/<file name>               capture bundles and note photos
///   _unfiled/…                                            notes and files with no field
public struct TheaterHost {
    public let joinCode: String
    public let name: String
    public let store: FieldStore

    public struct Contributor: Equatable, Sendable {
        public var name: String
        public var device: UUID
    }
    public private(set) var contributors: [PeerID: Contributor] = [:]
    /// What happened, newest last, for the Theater's activity list.
    public private(set) var activity: [String] = []

    private struct Upload {
        var offer: FileOffer
        var peer: PeerID
        var next = 0
        var received = 0
        var part: URL
    }
    private var uploads: [UUID: Upload] = [:]

    /// The folder for notes and files that name no field.
    public static let unfiled = "_unfiled"

    public init(name: String, joinCode: String, store: FieldStore) {
        self.name = name
        self.joinCode = joinCode
        self.store = store
    }

    public mutating func handle(_ message: GroupMessage, from peer: PeerID, now: Date) -> [Outgoing] {
        guard message.protocolVersion == GroupProtocol.version else {
            return [Outgoing(to: peer, .refused("This Theater speaks protocol \(GroupProtocol.version); the phone sent \(message.protocolVersion). Update the app."))]
        }
        if case let .hello(h) = message.body { return hello(h, peer: peer) }
        guard let who = contributors[peer] else { return [] }   // not joined: ignored

        switch message.body {
        case .bye:
            contributors[peer] = nil
            dropUploads(of: peer)
            return []
        case var .fieldSubmission(f):
            f.author = who.name
            return [Outgoing(to: peer, .receipt(register(f)))]
        case var .fieldNote(n):
            n.author = who.name
            return [Outgoing(to: peer, .receipt(save(n)))]
        case let .fileOffer(o):
            return begin(o, peer: peer).map { [Outgoing(to: peer, .receipt($0))] } ?? []
        case let .fileChunk(c):
            return chunk(c, peer: peer).map { [Outgoing(to: peer, .receipt($0))] } ?? []
        case let .fileDone(id):
            return finish(id, peer: peer).map { [Outgoing(to: peer, .receipt($0))] } ?? []
        default:
            return []
        }
    }

    /// A link closed: anything half-sent on it is dropped.
    public mutating func peerClosed(_ peer: PeerID) {
        contributors[peer] = nil
        dropUploads(of: peer)
    }

    /// A note an observed squad passed on (path 1).
    @discardableResult
    public mutating func recordNote(_ note: FieldNote, fromSquad squad: String) -> Receipt {
        var n = note
        n.author = "\(note.author) (\(squad))"
        return save(n)
    }

    // MARK: Joining

    private mutating func hello(_ h: Hello, peer: PeerID) -> [Outgoing] {
        guard h.role == .contributor else {
            return [Outgoing(to: peer, .refused("This is the Theater host. Squads are joined from a squad's iPad."))]
        }
        guard JoinCode.normalized(h.joinCode) == JoinCode.normalized(joinCode) else {
            return [Outgoing(to: peer, .refused("Wrong Theater code."))]
        }
        contributors[peer] = Contributor(name: h.name, device: h.device)
        log("\(h.name) connected")
        return [Outgoing(to: peer, .receipt(Receipt(id: h.device, status: .stored, detail: "Connected to \(name).")))]
    }

    // MARK: Fields and notes

    private mutating func register(_ f: FieldSubmission) -> Receipt {
        let errors = CourseValidator.problems(for: f.course).filter { $0.severity == .error }
        guard errors.isEmpty else {
            return Receipt(id: f.id, status: .refused, detail: errors.prefix(3).map(\.description).joined(separator: " "))
        }
        do {
            switch try store.register(f.course, source: "From \(f.author)", yaml: f.yaml) {
            case .added:
                log("\(f.author) added the field \(f.course.name)")
                return Receipt(id: f.id, status: .stored, detail: "\(f.course.name) is on the Theater's field list.")
            case let .updated(from):
                log("\(f.author) updated \(f.course.name) to v\(f.course.version)")
                return Receipt(id: f.id, status: .stored, detail: "Updated \(f.course.name) from v\(from) to v\(f.course.version).")
            case .unchanged:
                return Receipt(id: f.id, status: .stored, detail: "The Theater already has this version of \(f.course.name).")
            case let .olderIgnored(v):
                return Receipt(id: f.id, status: .refused, detail: "The Theater has \(f.course.name) v\(v), newer than this v\(f.course.version).")
            }
        } catch {
            return Receipt(id: f.id, status: .refused, detail: "Couldn't save it: \(error.localizedDescription)")
        }
    }

    private mutating func save(_ n: FieldNote) -> Receipt {
        let dir = notesDirectory(n.courseID)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var stored = n
            if let photo = n.photo {
                try photo.write(to: dir.appendingPathComponent("\(n.id.uuidString).jpg"), options: .atomic)
                stored.photo = nil   // kept beside the JSON, not inside it
            }
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            e.outputFormatting = [.prettyPrinted, .sortedKeys]
            try e.encode(stored).write(to: dir.appendingPathComponent("\(n.id.uuidString).json"), options: .atomic)
            log("Note from \(n.author)" + (n.courseID.map { " on \($0)" } ?? ""))
            return Receipt(id: n.id, status: .stored, detail: "Saved on \(name).")
        } catch {
            return Receipt(id: n.id, status: .refused, detail: "Couldn't save it: \(error.localizedDescription)")
        }
    }

    private func notesDirectory(_ courseID: String?) -> URL {
        store.courseDirectory(Self.folder(courseID)).appendingPathComponent("notes", isDirectory: true)
    }

    /// A course ID as a folder name; anything that isn't a plain name goes to `_unfiled`.
    static func folder(_ courseID: String?) -> String {
        guard let c = courseID, !c.isEmpty, !c.hasPrefix("."), !c.contains("/"), !c.contains("\\"), c.count <= 80 else {
            return unfiled
        }
        return c
    }

    // MARK: Files

    private mutating func begin(_ o: FileOffer, peer: PeerID) -> Receipt? {
        guard let name = o.safeName else { return Receipt(id: o.id, status: .refused, detail: "That file name isn't allowed.") }
        guard o.size > 0, o.size <= FileOffer.maxBytes else {
            return Receipt(id: o.id, status: .refused, detail: "Files go up to \(FileOffer.maxBytes / 1_000_000) MB.")
        }
        guard uploads[o.id] == nil else { return Receipt(id: o.id, status: .refused, detail: "Already sending that file.") }
        let incoming = store.root.appendingPathComponent(".incoming", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: incoming, withIntermediateDirectories: true)
            let part = incoming.appendingPathComponent("\(o.id.uuidString).part")
            FileManager.default.createFile(atPath: part.path, contents: nil)
            var offer = o
            offer.name = name
            uploads[o.id] = Upload(offer: offer, peer: peer, part: part)
            return nil
        } catch {
            return Receipt(id: o.id, status: .refused, detail: "Couldn't start it: \(error.localizedDescription)")
        }
    }

    private mutating func chunk(_ c: FileChunk, peer: PeerID) -> Receipt? {
        guard var u = uploads[c.file], u.peer == peer else { return nil }
        guard c.index == u.next, c.data.count <= FileOffer.chunkBytes, u.received + c.data.count <= u.offer.size else {
            abandon(c.file)
            return Receipt(id: c.file, status: .refused, detail: "A piece of the file arrived out of order or too big. Send it again.")
        }
        do {
            let h = try FileHandle(forWritingTo: u.part)
            defer { try? h.close() }
            try h.seekToEnd()
            try h.write(contentsOf: c.data)
        } catch {
            abandon(c.file)
            return Receipt(id: c.file, status: .refused, detail: "Couldn't write it: \(error.localizedDescription)")
        }
        u.next += 1
        u.received += c.data.count
        uploads[c.file] = u
        return nil
    }

    private mutating func finish(_ id: UUID, peer: PeerID) -> Receipt? {
        guard let u = uploads[id], u.peer == peer else { return nil }
        guard u.received == u.offer.size, let data = try? Data(contentsOf: u.part), data.sha256Hex == u.offer.sha256 else {
            abandon(id)
            return Receipt(id: id, status: .refused, detail: "The file didn't arrive whole. Send it again.")
        }
        let dir = store.courseDirectory(Self.folder(u.offer.courseID))
            .appendingPathComponent(u.offer.kind == .capture ? "captures" : "notes", isDirectory: true)
            .appendingPathComponent(u.offer.group.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(u.offer.name)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: u.part, to: dest)
            uploads[id] = nil
            log("Received \(u.offer.name) from \(contributors[peer]?.name ?? "a phone")")
            return Receipt(id: id, status: .stored, detail: "Saved on \(name).")
        } catch {
            abandon(id)
            return Receipt(id: id, status: .refused, detail: "Couldn't save it: \(error.localizedDescription)")
        }
    }

    private mutating func abandon(_ id: UUID) {
        if let u = uploads.removeValue(forKey: id) { try? FileManager.default.removeItem(at: u.part) }
    }

    private mutating func dropUploads(of peer: PeerID) {
        for (id, u) in uploads where u.peer == peer { abandon(id) }
    }

    private mutating func log(_ s: String) {
        activity.append(s)
        if activity.count > 200 { activity.removeFirst(activity.count - 200) }
    }

    // MARK: Reading back

    /// Notes saved for a field (or `_unfiled`), newest first, with their photo files if any.
    public static func notes(in store: FieldStore, courseID: String?) -> [(note: FieldNote, photo: URL?)] {
        let dir = store.courseDirectory(folder(courseID)).appendingPathComponent("notes", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url), let n = try? d.decode(FieldNote.self, from: data) else { return nil }
            let jpg = url.deletingPathExtension().appendingPathExtension("jpg")
            return (n, FileManager.default.fileExists(atPath: jpg.path) ? jpg : nil)
        }
        .sorted { $0.note.time > $1.note.time }
    }
}
