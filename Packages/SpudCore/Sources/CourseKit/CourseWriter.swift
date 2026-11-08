import Foundation
import CoreGeo

/// Writes a `Course` as a course file in the flat-key layout `CourseFile` reads
/// (see docs/COURSE_FORMAT.md). Used by the app's course survey.
public enum CourseWriter {
    public static func text(for course: Course, comment: String? = nil) -> String {
        var lines: [String] = ["# SpudGunGolf course file — flat dotted keys (see docs/COURSE_FORMAT.md)"]
        if let comment { lines += comment.split(separator: "\n").map { "# " + $0 } }
        lines += [
            "course.meta.format: \(course.format)",
            "course.meta.id: \(clean(course.id))",
            "course.meta.name: \(value(course.name))",
            "course.meta.version: \(course.version)"
        ]
        if let d = course.difficulty, !d.isEmpty { lines.append("course.meta.difficulty: \(value(d))") }
        lines.append("")
        for (i, p) in course.boundary.vertices.enumerated() { lines.append("course.boundary.\(i + 1): \(position(p))") }
        for hole in course.holes {
            let n = hole.number
            lines += [
                "",
                "hole.\(n).meta.name: \(value(hole.name))",
                "hole.\(n).meta.par: \(hole.par)",
                "hole.\(n).meta.downrange_play: \(hole.downrangePlay)"
            ]
            for (m, p) in hole.firingPoints.enumerated() { lines.append("hole.\(n).firing_point.\(m + 1): \(position(p))") }
            lines += [
                "hole.\(n).flag.position: \(position(hole.flag.position))",
                "hole.\(n).flag.pole_height_m: \(number(hole.flag.poleHeightM, 3))",
                "hole.\(n).flag.lean_deg: \(number(hole.flag.leanDeg, 2))",
                "hole.\(n).flag.in_radius_m: \(number(hole.flag.inRadiusM, 2))"
            ]
            if let lid = hole.lidDiameterM { lines.append("hole.\(n).lid.diameter_m: \(number(lid, 2))") }
            for h in hole.hazards {
                lines.append("hole.\(n).hazard.\(h.number).type: \(h.kind.rawValue)")
                lines.append("hole.\(n).hazard.\(h.number).points: " + h.area.vertices.map(position).joined(separator: "; "))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func position(_ p: GeoPoint) -> String { "\(number(p.latitude, 7)), \(number(p.longitude, 7))" }

    static func number(_ x: Double, _ places: Int) -> String {
        let s = String(format: "%.\(places)f", x)
        return s == "-" + String(format: "%.\(places)f", 0.0) ? String(format: "%.\(places)f", 0.0) : s
    }

    /// One line, no stray quotes at the ends (the reader would strip a matching pair).
    static func value(_ s: String) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        if let f = one.first, let l = one.last, one.count >= 2, f == l, f == "\"" || f == "'" { return "\"\(one)\"" }
        return one
    }

    /// An ID: lower-case letters, digits and dashes.
    public static func clean(_ id: String) -> String {
        let s = id.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return String(s).split(separator: "-").joined(separator: "-")
    }
}
