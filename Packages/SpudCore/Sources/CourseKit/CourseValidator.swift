import Foundation
import CoreGeo
import SafetyKit

/// Checks a built course: the geometry, the flag kit rules and every SafetyKit check that applies
/// to a course. Run on every load, including a course restored from the app's cache, so a change
/// to the safety limits re-checks courses that passed before.
public enum CourseValidator {
    public static func problems(for course: Course) -> [CourseProblem] {
        var out: [CourseProblem] = []
        let limits = Safety.limits

        if course.format != CourseRules.supportedFormat {
            out.append(CourseProblem(key: "course.meta.format", "Format \(course.format) isn't one this app reads."))
        }
        if course.id.isEmpty { out.append(CourseProblem(key: "course.meta.id", "The course id is empty.")) }
        if course.name.isEmpty { out.append(CourseProblem(key: "course.meta.name", "The course name is empty.")) }
        if course.version < 1 { out.append(CourseProblem(key: "course.meta.version", "The version must be 1 or more.")) }

        let boundary: GeoPolygon? = course.boundary.vertices.count >= 3 ? course.boundary : nil
        if boundary == nil { out.append(CourseProblem(key: "course.boundary", SafetyReason.noBoundary.description)) }

        if course.holes.isEmpty { out.append(CourseProblem(key: "hole.1", "The course has no holes.")) }
        var seen = Set<Int>()
        for hole in course.holes where !seen.insert(hole.number).inserted {
            out.append(CourseProblem(key: "hole.\(hole.number)", "Hole \(hole.number) appears twice."))
        }

        for hole in course.holes {
            out += problems(for: hole, boundary: boundary, limits: limits)
        }
        return out
    }

    static func problems(for hole: Hole, boundary: GeoPolygon?, limits: SafetyLimits) -> [CourseProblem] {
        var out: [CourseProblem] = []
        let p = "hole.\(hole.number)"
        let title = "Hole \(hole.number)"
        let flag = hole.flag

        if hole.name.isEmpty { out.append(CourseProblem(key: "\(p).meta.name", "\(title) has no name.")) }
        if hole.par < 1 { out.append(CourseProblem(key: "\(p).meta.par", "\(title): par must be 1 or more.")) }

        // Flag kit and measurement.
        let heights = CourseRules.poleHeightRangeM
        if !heights.contains(flag.poleHeightM) {
            out.append(CourseProblem(key: "\(p).flag.pole_height_m", String(format:
                "%@: a pole height of %.3f m is outside the flag kit's %.2f–%.2f m (8 to 12 ft). Re-measure the pole.",
                title, flag.poleHeightM, heights.lowerBound, heights.upperBound)))
        }
        if flag.leanDeg < 0 {
            out.append(CourseProblem(key: "\(p).flag.lean_deg", "\(title): lean can't be negative; give the total lean from the lean check."))
        } else if flag.leanDeg >= CourseRules.maxLeanDeg {
            out.append(CourseProblem(key: "\(p).flag.lean_deg", String(format:
                "%@: the pole leans %.2f°; it must be under %.1f°. Re-guy the pole and repeat the lean check.",
                title, flag.leanDeg, CourseRules.maxLeanDeg)))
        }
        if !(flag.inRadiusM > 0 && flag.inRadiusM <= CourseRules.maxInRadiusM) {
            out.append(CourseProblem(key: "\(p).flag.in_radius_m", String(format:
                "%@: the ring radius must be over 0 and at most %.0f m.", title, CourseRules.maxInRadiusM)))
        }
        if let lid = hole.lidDiameterM, !(lid > 0 && lid < 2) {
            out.append(CourseProblem(key: "\(p).lid.diameter_m", "\(title): a lid diameter must be over 0 and under 2 m."))
        }
        for hazard in hole.hazards where hazard.area.vertices.count < 3 {
            out.append(CourseProblem(key: "\(p).hazard.\(hazard.number).points",
                "\(title), hazard \(hazard.number): an area needs at least 3 corners."))
        }

        // Geometry and safety.
        if let boundary, !boundary.contains(flag.position) {
            out.append(CourseProblem(key: "\(p).flag.position", "\(title): the flag is outside the course boundary."))
        }
        if hole.firingPoints.isEmpty {
            out.append(CourseProblem(key: "\(p).firing_point.1", "\(title) has no firing point."))
        }
        for (i, start) in hole.firingPoints.enumerated() {
            let key = "\(p).firing_point.\(i + 1)"
            let where_ = "\(title), firing point \(i + 1)"
            if let boundary, !boundary.contains(start) {
                out.append(CourseProblem(key: key, "\(where_): the firing point is outside the course boundary."))
            }
            let distance = Geo.distance(start, flag.position)
            if distance < 1 {
                out.append(CourseProblem(key: key, "\(where_): the firing point is on the flag."))
                continue
            }
            if distance > limits.maxSolutionRange {
                let reason = SafetyReason.beyondSolutionRange(distance: distance, limit: limits.maxSolutionRange)
                out.append(CourseProblem(key: key, "\(where_): \(reason.description)"))
            }
            // Without a boundary the course-level problem above already says so, once.
            guard let boundary else { continue }
            for reason in Safety.checkFan(start: start, hole: flag.position, boundary: boundary).reasons {
                out.append(CourseProblem(key: key, "\(where_): \(reason.description)"))
            }
        }
        return out
    }
}
