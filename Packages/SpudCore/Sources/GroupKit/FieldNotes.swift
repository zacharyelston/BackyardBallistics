import Foundation
import CoreGeo
import CourseKit

// Field notes, new fields and files from players, by two paths:
//
// 1. Through the squad: a member's phone sends a note or a surveyed field to the squad leader.
//    Notes go on to the squad's observers (the Theater host). The leader can adopt a new field for
//    the squad between holes, which sends it to observers too, and the Theater registers it.
// 2. Direct to the Theater host: any phone joins the Theater (its own code, `Hello.Role.contributor`)
//    and sends notes, fields and files (capture photos and their data) with no squad running.
//
// None of it carries firing data, and nothing here feeds SafetyKit.

/// A note pinned to the field: something seen, a hazard, a capture's target.
public struct FieldNote: Codable, Equatable, Sendable, Identifiable {
    public static let maxText = 500
    /// A note's photo travels inline only when small; larger files go as `FileOffer`s to the Theater.
    public static let maxInlinePhotoBytes = 300_000

    public var id: UUID
    public var author: String
    public var time: Date
    /// The field it belongs to, if known.
    public var courseID: String?
    public var at: GeoPoint?
    public var accuracy: Double?
    public var text: String
    /// A small JPEG, inline.
    public var photo: Data?

    public init(id: UUID = UUID(), author: String, time: Date, courseID: String? = nil, at: GeoPoint? = nil,
                accuracy: Double? = nil, text: String, photo: Data? = nil) {
        self.id = id
        self.author = author
        self.time = time
        self.courseID = courseID
        self.at = at
        self.accuracy = accuracy
        self.text = String(text.prefix(Self.maxText))
        self.photo = photo.flatMap { $0.count <= Self.maxInlinePhotoBytes ? $0 : nil }
    }
}

/// A field (course) a player surveyed or loaded, offered to the squad leader or the Theater.
public struct FieldSubmission: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var author: String
    public var time: Date
    public var course: Course
    /// The course file's text, when it came from one.
    public var yaml: String?
    public var note: String?

    public init(id: UUID = UUID(), author: String, time: Date, course: Course, yaml: String? = nil, note: String? = nil) {
        self.id = id
        self.author = author
        self.time = time
        self.course = course
        self.yaml = yaml
        self.note = note
    }
}

/// A file about to be sent to the Theater in chunks.
public struct FileOffer: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A file of a target capture bundle (a JPEG, or capture.json).
        case capture
        /// A full-size photo for a field note.
        case notePhoto
    }
    public static let maxBytes = 50_000_000
    public static let chunkBytes = 256 * 1024

    public var id: UUID
    public var kind: Kind
    /// The bundle or note it belongs to: files with the same group land in one folder.
    public var group: UUID
    /// A plain file name, no folders.
    public var name: String
    public var size: Int
    /// SHA-256 of the whole file, hex.
    public var sha256: String
    public var courseID: String?

    public init(id: UUID = UUID(), kind: Kind, group: UUID, name: String, size: Int, sha256: String, courseID: String?) {
        self.id = id
        self.kind = kind
        self.group = group
        self.name = name
        self.size = size
        self.sha256 = sha256
        self.courseID = courseID
    }

    /// Only a plain file name: no folders, no hidden files, nothing that could escape the folder.
    public var safeName: String? {
        let n = (name as NSString).lastPathComponent
        guard !n.isEmpty, n == name, !n.hasPrefix("."), !n.contains("/"), !n.contains("\\"), n.count <= 120 else { return nil }
        return n
    }

    public var chunkCount: Int { max(1, (size + Self.chunkBytes - 1) / Self.chunkBytes) }
}

public struct FileChunk: Codable, Equatable, Sendable {
    public var file: UUID
    public var index: Int
    public var data: Data
    public init(file: UUID, index: Int, data: Data) {
        self.file = file
        self.index = index
        self.data = data
    }
}

/// What the receiver did with a note, field or file.
public struct Receipt: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// Got it; for a field sent to the leader, waiting for the leader to adopt it.
        case received
        /// Saved (Theater), or adopted for the squad (leader).
        case stored
        case refused
    }
    public var id: UUID
    public var status: Status
    public var detail: String

    public init(id: UUID, status: Status, detail: String = "") {
        self.id = id
        self.status = status
        self.detail = detail
    }
}

public extension Data {
    /// SHA-256, hex.
    var sha256Hex: String { CourseFingerprint.sha256Hex(self) }
}
