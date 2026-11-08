import Foundation
import CoreGeo

/// Reads the flat dotted-key course file described in docs/COURSE_FORMAT.md.
///
/// This is deliberately not a YAML parser: every line is `key: value`, a comment or blank.
/// Nothing here throws or traps on bad input; everything wrong comes back as a `CourseProblem`.
public enum CourseFile {
    public struct Entry: Equatable, Sendable {
        public var key: String
        public var value: String
        public var line: Int
    }

    // MARK: Loading

    /// Reads raw bytes (from the bundle, a download or disk), then parses and validates them.
    public static func load(data: Data) -> CourseLoadResult {
        guard data.count <= CourseRules.maxFileBytes else {
            return CourseLoadResult(course: nil, problems: [CourseProblem(
                "The file is \(data.count / 1024) KB, over the \(CourseRules.maxFileBytes / 1024) KB limit for a course file.")])
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return CourseLoadResult(course: nil, problems: [CourseProblem("The file isn't UTF-8 text.")])
        }
        return load(text)
    }

    /// Parses and validates a course file's text.
    public static func load(_ text: String) -> CourseLoadResult {
        let (entries, lineProblems) = Self.entries(in: text)
        var builder = Builder(entries: entries)
        let course = builder.build()
        var problems = lineProblems + builder.problems
        if let course {
            let lines = Dictionary(entries.map { ($0.key, $0.line) }, uniquingKeysWith: { first, _ in first })
            problems += CourseValidator.problems(for: course).map { problem in
                var p = problem
                if p.line == nil, let key = p.key { p.line = lines[key] }
                return p
            }
        }
        return CourseLoadResult(course: course, problems: problems)
    }

    // MARK: Lines

    /// Splits a file into `key: value` entries. Blank lines and lines starting with `#` are skipped.
    /// A repeated key keeps its first value and is reported.
    public static func entries(in text: String) -> (entries: [Entry], problems: [CourseProblem]) {
        var entries: [Entry] = []
        var problems: [CourseProblem] = []
        var firstLine: [String: Int] = [:]
        let body = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text

        for (index, raw) in body.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let lineNumber = index + 1
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let colon = line.firstIndex(of: ":") else {
                problems.append(CourseProblem(line: lineNumber, "Expected `key: value`, found “\(clip(line))”."))
                continue
            }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            guard isValidKey(key) else {
                problems.append(CourseProblem(line: lineNumber, "“\(clip(key))” isn't a key: use lower-case dotted names like `hole.1.meta.par`."))
                continue
            }
            guard !value.isEmpty else {
                problems.append(CourseProblem(line: lineNumber, key: key, "Has no value."))
                continue
            }
            if let first = firstLine[key] {
                problems.append(CourseProblem(line: lineNumber, key: key, "Duplicate key; line \(first) already sets it."))
                continue
            }
            firstLine[key] = lineNumber
            entries.append(Entry(key: key, value: value, line: lineNumber))
        }
        return (entries, problems)
    }

    static func isValidKey(_ key: String) -> Bool {
        guard !key.isEmpty, !key.hasPrefix("."), !key.hasSuffix("."), !key.contains("..") else { return false }
        return key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "." }
    }

    /// Drops one pair of matching quotes, as people used to YAML often add them.
    static func unquote(_ value: String) -> String {
        guard value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" else { return value }
        return String(value.dropFirst().dropLast())
    }

    static func clip(_ s: String) -> String { s.count > 40 ? String(s.prefix(40)) + "…" : s }

    // MARK: Values

    /// A plain decimal such as `-71.0589` or `2.438`. Rejects `nan`, `inf`, hex and exponents.
    static func decimal(_ s: String) -> Double? {
        var digits = Substring(s)
        if digits.first == "-" || digits.first == "+" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits != ".",
              digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              digits.filter({ $0 == "." }).count <= 1,
              let value = Double(s), value.isFinite else { return nil }
        return value
    }

    static func integer(_ s: String) -> Int? {
        var digits = Substring(s)
        if digits.first == "-" { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }

    /// `latitude, longitude` in decimal degrees.
    static func point(_ s: String) -> GeoPoint? {
        let parts = s.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let lat = decimal(parts[0]), let lon = decimal(parts[1]),
              (-90...90).contains(lat), (-180...180).contains(lon) else { return nil }
        return GeoPoint(latitude: lat, longitude: lon)
    }

    /// `lat, lon; lat, lon; …`. A trailing semicolon is allowed.
    static func points(_ s: String) -> [GeoPoint]? {
        var parts = s.split(separator: ";", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.last?.isEmpty == true { parts.removeLast() }
        var out: [GeoPoint] = []
        for part in parts {
            guard let p = point(part) else { return nil }
            out.append(p)
        }
        return out.isEmpty ? nil : out
    }

    /// A 1-based index segment: `1`, `2`, `10`; not `0`, `01` or `x`.
    static func index(_ s: Substring) -> Int? {
        guard let first = s.first, first != "0", s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(s)
    }
}

// MARK: - Building the model

private struct Builder {
    let byKey: [String: CourseFile.Entry]
    let entries: [CourseFile.Entry]
    var used: Set<String> = []
    var problems: [CourseProblem] = []

    init(entries: [CourseFile.Entry]) {
        self.entries = entries
        self.byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    }

    mutating func build() -> Course? {
        let format = int("course.meta.format", required: true)
        if let format, format != CourseRules.supportedFormat {
            problems.append(problem("course.meta.format",
                "Format \(format) isn't one this app reads (it reads format \(CourseRules.supportedFormat)). Update the app or the file."))
            markAllUsed()
            return nil
        }
        let id = string("course.meta.id", required: true)
        let name = string("course.meta.name", required: true)
        let version = int("course.meta.version", required: true)
        let difficulty = string("course.meta.difficulty", required: false)

        let boundary = indexed(prefix: ["course", "boundary"], what: "boundary corner").compactMap { n in
            point("course.boundary.\(n)", required: true)
        }
        if boundary.isEmpty {
            problems.append(CourseProblem(key: "course.boundary.1", "The course has no boundary (`course.boundary.1`, `.2`, …)."))
        } else if boundary.count < 3 {
            problems.append(CourseProblem(key: "course.boundary", "The boundary needs at least 3 corners; it has \(boundary.count)."))
        }

        let holes = indexed(prefix: ["hole"], what: "hole").compactMap { buildHole($0) }
        if holes.isEmpty && !entries.contains(where: { $0.key.hasPrefix("hole.") }) {
            problems.append(CourseProblem(key: "hole.1", "The course has no holes."))
        }
        reportUnknownKeys()

        guard let format, let id, let name, let version, boundary.count >= 3 else { return nil }
        return Course(format: format, id: id, name: name, version: version, difficulty: difficulty,
                      boundary: GeoPolygon(boundary), holes: holes)
    }

    private mutating func buildHole(_ n: Int) -> Hole? {
        let p = "hole.\(n)"
        let name = string("\(p).meta.name", required: true)
        let par = int("\(p).meta.par", required: true)
        let downrange = bool("\(p).meta.downrange_play") ?? false

        let firingIndices = indexed(prefix: ["hole", "\(n)", "firing_point"], what: "firing point")
        let firingPoints = firingIndices.compactMap { point("\(p).firing_point.\($0)", required: true) }
        if firingIndices.isEmpty {
            problems.append(CourseProblem(key: "\(p).firing_point.1", "Hole \(n) has no firing point."))
        }

        let position = point("\(p).flag.position", required: true)
        let height = double("\(p).flag.pole_height_m", required: true)
        let lean = double("\(p).flag.lean_deg", required: true)
        let radius = double("\(p).flag.in_radius_m", required: false) ?? Flag.defaultInRadiusM
        let lid = double("\(p).lid.diameter_m", required: false)

        let hazards = indexed(prefix: ["hole", "\(n)", "hazard"], what: "hazard").compactMap { k -> Hazard? in
            let hp = "\(p).hazard.\(k)"
            let kindText = string("\(hp).type", required: true)
            let kind = kindText.flatMap(Hazard.Kind.init(rawValue:))
            if let kindText, kind == nil {
                problems.append(problem("\(hp).type", "“\(CourseFile.clip(kindText))” isn't a hazard type; use water, sand or ob."))
            }
            let area = points("\(hp).points", required: true)
            guard let kind, let area else { return nil }
            return Hazard(number: k, kind: kind, area: GeoPolygon(area))
        }

        guard let name, let par, let position, let height, let lean, !firingPoints.isEmpty,
              firingPoints.count == firingIndices.count else { return nil }
        return Hole(number: n, name: name, par: par, downrangePlay: downrange, firingPoints: firingPoints,
                    flag: Flag(position: position, poleHeightM: height, leanDeg: lean, inRadiusM: radius),
                    lidDiameterM: lid, hazards: hazards)
    }

    // MARK: Indexed families

    /// The `N` values under `prefix.N…`, sorted. Reports bad and missing numbers.
    private mutating func indexed(prefix: [String], what: String) -> [Int] {
        var found = Set<Int>()
        for entry in entries {
            let parts = entry.key.split(separator: ".")
            guard parts.count > prefix.count, zip(parts, prefix).allSatisfy({ $0 == $1 }) else { continue }
            let segment = parts[prefix.count]
            if let n = CourseFile.index(segment) {
                found.insert(n)
            } else if !used.contains(entry.key) {
                used.insert(entry.key)
                problems.append(CourseProblem(line: entry.line, key: entry.key,
                    "“\(segment)” isn't a \(what) number; number them 1, 2, 3 and so on."))
            }
        }
        let sorted = found.sorted()
        if let last = sorted.last {
            let missing = (1...last).filter { !found.contains($0) }
            if !missing.isEmpty {
                let name = prefix.joined(separator: ".")
                problems.append(CourseProblem(key: name,
                    "Missing \(what) \(missing.map(String.init).joined(separator: ", ")); \(name) numbers must run 1, 2, 3 without gaps."))
            }
        }
        return sorted
    }

    // MARK: Typed reads

    private mutating func raw(_ key: String, required: Bool) -> CourseFile.Entry? {
        guard let entry = byKey[key] else {
            if required { problems.append(CourseProblem(key: key, "Required key is missing.")) }
            return nil
        }
        used.insert(key)
        return entry
    }

    private mutating func string(_ key: String, required: Bool) -> String? { raw(key, required: required)?.value }

    private mutating func int(_ key: String, required: Bool) -> Int? {
        guard let e = raw(key, required: required) else { return nil }
        guard let v = CourseFile.integer(e.value) else {
            problems.append(bad(e, "a whole number")); return nil
        }
        return v
    }

    private mutating func double(_ key: String, required: Bool) -> Double? {
        guard let e = raw(key, required: required) else { return nil }
        guard let v = CourseFile.decimal(e.value) else {
            problems.append(bad(e, "a number such as 2.438")); return nil
        }
        return v
    }

    private mutating func bool(_ key: String) -> Bool? {
        guard let e = raw(key, required: false) else { return nil }
        switch e.value {
        case "true": return true
        case "false": return false
        default: problems.append(bad(e, "true or false")); return nil
        }
    }

    private mutating func point(_ key: String, required: Bool) -> GeoPoint? {
        guard let e = raw(key, required: required) else { return nil }
        guard let v = CourseFile.point(e.value) else {
            problems.append(bad(e, "`latitude, longitude` in decimal degrees")); return nil
        }
        return v
    }

    private mutating func points(_ key: String, required: Bool) -> [GeoPoint]? {
        guard let e = raw(key, required: required) else { return nil }
        guard let v = CourseFile.points(e.value) else {
            problems.append(bad(e, "corners as `lat, lon; lat, lon; …`")); return nil
        }
        return v
    }

    private func bad(_ e: CourseFile.Entry, _ expected: String) -> CourseProblem {
        CourseProblem(line: e.line, key: e.key, "“\(CourseFile.clip(e.value))” isn't valid; expected \(expected).")
    }

    private func problem(_ key: String, _ message: String) -> CourseProblem {
        CourseProblem(line: byKey[key]?.line, key: key, message)
    }

    private mutating func markAllUsed() { used.formUnion(byKey.keys) }

    private mutating func reportUnknownKeys() {
        for entry in entries where !used.contains(entry.key) {
            problems.append(CourseProblem(.warning, line: entry.line, key: entry.key, "Unknown key; ignored."))
        }
    }
}
