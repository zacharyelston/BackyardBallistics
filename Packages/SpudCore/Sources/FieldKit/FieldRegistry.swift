import Foundation
import CourseKit

// The Theater host's list of fields: every course it has been given, kept whether or not anyone is
// playing it. Each field is a folder in `FieldStore.root`, named by the course ID, holding:
//
//   field.json          RegisteredField: name, version, where it came from, when added and last seen
//   course.json         the course
//   course.yaml         the original file, when it was imported from one
//   versions/<v>.json   earlier versions, kept when a newer one replaces them
//   elevation.json      bare-earth heights (the 3D view)
//   meshes/<id>/        georeferenced meshes (spud-mesh)
//   captures/<name>/    target captures from phones
//
// Forgetting a field moves its folder to `<root>/.forgotten/`, never deletes it.

/// One field the Theater host knows.
public struct RegisteredField: Codable, Equatable, Identifiable, Sendable {
    /// The course ID; also the folder's name.
    public var id: String
    public var name: String
    public var version: Int
    public var holes: Int
    public var totalPar: Int
    public var registeredAt: Date
    public var updatedAt: Date
    /// Where it came from: "Imported from course.yaml", "From squad Red", …
    public var source: String
    /// When a squad last played it while this host watched.
    public var lastSeen: Date?
}

public enum FieldRegistration: Equatable, Sendable {
    case added
    case updated(from: Int)
    /// The same version was already here.
    case unchanged
    /// The host already has a newer version; the older one isn't stored.
    case olderIgnored(registered: Int)
}

public extension FieldStore {
    /// Every registered field with its course, by name.
    func fields() -> [(field: RegisteredField, course: Course)] {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                                 options: [.skipsHiddenFiles])) ?? []
        return dirs.compactMap { dir in
            guard let f: RegisteredField = Self.read(dir.appendingPathComponent("field.json")),
                  let c: Course = Self.read(dir.appendingPathComponent("course.json")) else { return nil }
            return (f, c)
        }
        .sorted { $0.field.name.localizedCaseInsensitiveCompare($1.field.name) == .orderedAscending }
    }

    func field(_ courseID: String) -> (field: RegisteredField, course: Course)? {
        let dir = courseDirectory(courseID)
        guard let f: RegisteredField = Self.read(dir.appendingPathComponent("field.json")),
              let c: Course = Self.read(dir.appendingPathComponent("course.json")) else { return nil }
        return (f, c)
    }

    /// Adds a course, or updates it to a newer version (the old one goes to `versions/`).
    @discardableResult
    func register(_ course: Course, source: String, yaml: String? = nil, now: Date = Date()) throws -> FieldRegistration {
        let dir = courseDirectory(course.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = field(course.id)
        if let e = existing {
            if e.course.version > course.version { return .olderIgnored(registered: e.course.version) }
            if e.course.version == course.version && e.course == course { return .unchanged }
            // Keep what it replaces.
            let versions = dir.appendingPathComponent("versions", isDirectory: true)
            try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
            try Self.write(e.course, to: versions.appendingPathComponent("\(e.course.version).json"))
        }
        let record = RegisteredField(id: course.id, name: course.name, version: course.version, holes: course.holes.count,
                                     totalPar: course.totalPar, registeredAt: existing?.field.registeredAt ?? now,
                                     updatedAt: now, source: source, lastSeen: existing?.field.lastSeen)
        try Self.write(course, to: dir.appendingPathComponent("course.json"))
        if let yaml { try yaml.write(to: dir.appendingPathComponent("course.yaml"), atomically: true, encoding: .utf8) }
        try Self.write(record, to: dir.appendingPathComponent("field.json"))
        guard let e = existing else { return .added }
        return .updated(from: e.course.version)
    }

    /// Notes that a squad is playing the field now.
    func markSeen(_ courseID: String, at date: Date = Date()) {
        let url = courseDirectory(courseID).appendingPathComponent("field.json")
        guard var f: RegisteredField = Self.read(url) else { return }
        f.lastSeen = date
        try? Self.write(f, to: url)
    }

    /// Moves a field's folder to `<root>/.forgotten/<id>-<time>`. Returns where it went.
    @discardableResult
    func forget(_ courseID: String, now: Date = Date()) throws -> URL {
        let forgotten = root.appendingPathComponent(".forgotten", isDirectory: true)
        try FileManager.default.createDirectory(at: forgotten, withIntermediateDirectories: true)
        let stamp = Int(now.timeIntervalSince1970)
        let dest = forgotten.appendingPathComponent("\(courseID)-\(stamp)", isDirectory: true)
        try FileManager.default.moveItem(at: courseDirectory(courseID), to: dest)
        return dest
    }

    /// The field's captures folder (`captures/`), created on demand.
    func capturesDirectory(_ courseID: String) -> URL {
        courseDirectory(courseID).appendingPathComponent("captures", isDirectory: true)
    }

    // MARK: JSON

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(T.self, from: data)
    }

    private static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(value).write(to: url, options: .atomic)
    }
}
