import Foundation

/// One thing wrong with a course file, in words a course designer can act on.
public struct CourseProblem: Codable, Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum Severity: String, Codable, Sendable {
        /// The course is refused.
        case error
        /// Worth fixing, but the course can still be played.
        case warning
    }

    /// Problems that only matter when something is really fired.
    public enum Kind: String, Codable, Sendable {
        /// A firing point's safety fan leaves the boundary. Practice, which fires nothing, may still use the course.
        case fan
    }

    public var severity: Severity
    /// Set for problems that practice can live with; nil for everything else.
    public var kind: Kind?
    /// 1-based line in the file, when the problem is on one line.
    public var line: Int?
    /// The dotted key involved, when there is one.
    public var key: String?
    public var message: String

    public init(_ severity: Severity, line: Int? = nil, key: String? = nil, kind: Kind? = nil, _ message: String) {
        self.severity = severity
        self.kind = kind
        self.line = line
        self.key = key
        self.message = message
    }

    /// An error: the course is refused.
    public init(line: Int? = nil, key: String? = nil, kind: Kind? = nil, _ message: String) {
        self.init(.error, line: line, key: key, kind: kind, message)
    }

    public var description: String {
        var prefix = ""
        if let line { prefix += "Line \(line): " }
        if let key { prefix += "\(key): " }
        return prefix + message
    }
}

/// What came out of reading a course file.
public struct CourseLoadResult: Codable, Equatable, Sendable {
    /// As much of the course as could be built, even if it has problems. Nil when the file
    /// doesn't describe a course at all (no usable `course.meta` or boundary).
    public var course: Course?
    public var problems: [CourseProblem]

    public init(course: Course?, problems: [CourseProblem]) {
        self.course = course
        self.problems = problems
    }

    public var errors: [CourseProblem] { problems.filter { $0.severity == .error } }
    public var warnings: [CourseProblem] { problems.filter { $0.severity == .warning } }

    /// The course, only if it passed every check. A course with any error is refused.
    public var playableCourse: Course? { errors.isEmpty ? course : nil }

    /// The course for practice: playable, or refused only because a safety fan leaves the boundary.
    /// Practice fires nothing, so the fan doesn't apply; real rounds still need `playableCourse`.
    public var practiceCourse: Course? { errors.allSatisfy { $0.kind == .fan } ? course : nil }

    /// Usable for practice and demos, but not for real rounds.
    public var isPracticeOnly: Bool { playableCourse == nil && practiceCourse != nil }
}
