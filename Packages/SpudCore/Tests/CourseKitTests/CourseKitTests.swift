import XCTest
import CoreGeo
import SafetyKit
import RangingKit
@testable import CourseKit

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

private func sampleText() throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent("courses/sample-course.yaml"), encoding: .utf8)
}

/// The sample with one line swapped, for building broken courses.
private func sample(replacing old: String, with new: String) throws -> String {
    let text = try sampleText()
    XCTAssertTrue(text.contains(old), "sample no longer has: \(old)")
    return text.replacingOccurrences(of: old, with: new)
}

private func messages(_ r: CourseLoadResult) -> String { r.problems.map(\.description).joined(separator: "\n") }

final class SampleCourseTests: XCTestCase {
    func testSampleCourseLoadsCleanly() throws {
        let result = CourseFile.load(try sampleText())
        XCTAssertEqual(result.problems, [], messages(result))
        let course = try XCTUnwrap(result.playableCourse)

        XCTAssertEqual(course.format, 1)
        XCTAssertEqual(course.id, "elm-st")
        XCTAssertEqual(course.name, "Elm Street Backyard")
        XCTAssertEqual(course.version, 4)
        XCTAssertEqual(course.difficulty, "easy")
        XCTAssertEqual(course.boundary.vertices.count, 4)
        XCTAssertEqual(course.boundary.vertices[0], GeoPoint(latitude: 42.360010, longitude: -71.059010))
        XCTAssertEqual(course.holes.map(\.number), [1, 2])
        XCTAssertEqual(course.totalPar, 7)

        let h1 = course.holes[0]
        XCTAssertEqual(h1.name, "The Driveway")
        XCTAssertEqual(h1.par, 3)
        XCTAssertFalse(h1.downrangePlay)
        XCTAssertEqual(h1.firingPoints.count, 1)
        XCTAssertEqual(h1.flag.poleHeightM, 2.438)
        XCTAssertEqual(h1.flag.leanDeg, 0.3)
        XCTAssertEqual(h1.flag.inRadiusM, 1.0)
        XCTAssertEqual(h1.lidDiameterM, 0.58)
        XCTAssertEqual(h1.hazards, [])
        XCTAssertEqual(h1.firingDistances[0], 70, accuracy: 0.5)

        let h2 = course.holes[1]
        XCTAssertEqual(h2.name, "Garden Hose")
        XCTAssertTrue(h2.downrangePlay)
        XCTAssertEqual(h2.firingPoints.count, 2)
        XCTAssertEqual(h2.flag.inRadiusM, 1.5)
        XCTAssertNil(h2.lidDiameterM)
        XCTAssertEqual(h2.hazards.count, 1)
        XCTAssertEqual(h2.hazards[0].kind, .water)
        XCTAssertEqual(h2.hazards[0].area.vertices.count, 4)
        for d in h2.firingDistances {
            XCTAssertLessThanOrEqual(d, SafetyLimits.current.maxSolutionRange)
        }
    }

    func testSampleCourseSurvivesJSONRoundTrip() throws {
        let course = try XCTUnwrap(CourseFile.load(try sampleText()).course)
        let data = try JSONEncoder().encode(course)
        let back = try JSONDecoder().decode(Course.self, from: data)
        XCTAssertEqual(back, course)
        XCTAssertEqual(CourseValidator.problems(for: back), [])
    }

    func testLoadFromDataMatchesText() throws {
        let text = try sampleText()
        XCTAssertEqual(CourseFile.load(data: Data(text.utf8)), CourseFile.load(text))
    }
}

final class MalformedFileTests: XCTestCase {
    func testGarbageNeverCrashes() {
        let inputs = ["", "\n\n", "# only a comment", ":", "::::", "key", "hole.: 3", "course.meta.format: 1",
                      String(repeating: "x", count: 10_000), "hole.1.meta.par: 99999999999999999999999",
                      "\u{FEFF}course.meta.id: x\r\ncourse.meta.name: y\r\n", "hole.9999999999999999999999.meta.name: x"]
        for text in inputs {
            let result = CourseFile.load(text)
            XCTAssertNil(result.playableCourse, text)
            XCTAssertFalse(result.errors.isEmpty, text)
        }
        let binary = Data([0xFF, 0xFE, 0x00, 0xC3, 0x28])
        XCTAssertEqual(CourseFile.load(data: binary).errors.count, 1)
        let huge = Data(repeating: 0x41, count: CourseRules.maxFileBytes + 1)
        XCTAssertEqual(CourseFile.load(data: huge).errors.count, 1)
    }

    func testMalformedFileReportsEachProblemWithItsLine() throws {
        let text = """
        # broken on purpose
        course.meta.format: 1
        course.meta.id: broken
        course.meta.name: Broken Course
        course.meta.version: three
        course.boundary.1: 42.360010, -71.059010
        course.boundary.2: 42.360010, -71.057600
        course.boundary.3: 42.361400, -71.057600
        course.boundary.4: 42.361400, -71.059010
        hole.1.meta.name: No Firing Point
        hole.1.meta.par: 3
        hole.1.flag.position: 42.360729, -71.058280
        hole.1.flag.pole_height_m: 2.4.3
        hole.1.flag.lean_deg: 0.3
        hole.1.meta.name: Again
        hole.1.meta.downrange_play: yes
        this line has no colon
        hole.2.meta.name: Bad Point
        hole.2.meta.par: 4
        hole.2.firing_point.1: 42.360370
        hole.2.flag.position: 142.0, -71.058280
        hole.2.flag.pole_height_m: nan
        hole.2.flag.lean_deg: 0.2
        hole.2.hazard.1.type: lava
        hole.2.hazard.1.points: 1, 2; 3, 4; 5, 6
        hole.2.flag.colour: orange
        """
        let result = CourseFile.load(text)
        XCTAssertNil(result.playableCourse)
        // Meta has a bad version, so there's no course at all, but every line problem is still reported.
        XCTAssertNil(result.course)

        func has(line: Int?, key: String?, _ fragment: String, file: StaticString = #filePath, fileLine: UInt = #line) {
            XCTAssertTrue(result.problems.contains { $0.line == line && $0.key == key && $0.message.contains(fragment) },
                          "no problem at line \(line ?? -1) \(key ?? "") containing “\(fragment)”:\n\(messages(result))",
                          file: file, line: fileLine)
        }
        has(line: 5, key: "course.meta.version", "expected a whole number")
        has(line: 13, key: "hole.1.flag.pole_height_m", "expected a number")
        has(line: 15, key: "hole.1.meta.name", "Duplicate key; line 10")
        has(line: 16, key: "hole.1.meta.downrange_play", "true or false")
        has(line: 17, key: nil, "Expected `key: value`")
        has(line: nil, key: "hole.1.firing_point.1", "Hole 1 has no firing point")
        has(line: 20, key: "hole.2.firing_point.1", "latitude, longitude")
        has(line: 21, key: "hole.2.flag.position", "latitude, longitude")
        has(line: 22, key: "hole.2.flag.pole_height_m", "expected a number")
        has(line: 24, key: "hole.2.hazard.1.type", "water, sand or ob")
        let unknown = try XCTUnwrap(result.problems.first { $0.key == "hole.2.flag.colour" })
        XCTAssertEqual(unknown.severity, .warning)
    }

    func testMissingRequiredKeysAndNumberingGaps() throws {
        var text = try sample(replacing: "hole.1.flag.lean_deg: 0.3\n", with: "")
        text = text.replacingOccurrences(of: "course.boundary.3:", with: "course.boundary.5:")
        text = text.replacingOccurrences(of: "hole.2.", with: "hole.3.")
        let result = CourseFile.load(text)
        let all = messages(result)
        XCTAssertTrue(result.problems.contains { $0.key == "hole.1.flag.lean_deg" && $0.message == "Required key is missing." }, all)
        XCTAssertTrue(all.contains("Missing boundary corner 3;"), all)
        XCTAssertTrue(all.contains("Missing hole 2"), all)
        XCTAssertNil(result.playableCourse)
        // Hole 1 can't be built without its lean, so only hole 3 survives.
        XCTAssertEqual(result.course?.holes.map(\.number), [3])
    }

    func testBadIndexesAndUnsupportedFormat() throws {
        let zero = CourseFile.load(try sample(replacing: "hole.1.meta.par: 3", with: "hole.01.meta.par: 3"))
        XCTAssertTrue(zero.problems.contains { $0.key == "hole.01.meta.par" && $0.message.contains("isn't a hole number") }, messages(zero))
        XCTAssertTrue(zero.problems.contains { $0.key == "hole.1.meta.par" && $0.message == "Required key is missing." })

        let future = CourseFile.load(try sample(replacing: "course.meta.format: 1", with: "course.meta.format: 2"))
        XCTAssertNil(future.course)
        XCTAssertEqual(future.errors.count, 1, messages(future))
        XCTAssertTrue(future.errors[0].message.contains("Format 2"))
    }

    func testQuotedValuesAndTrailingSemicolonAreAccepted() throws {
        var text = try sample(replacing: "course.meta.name: Elm Street Backyard", with: "course.meta.name: \"Elm Street: Backyard\"")
        text = text.replacingOccurrences(of: "42.360981, -71.058426\n", with: "42.360981, -71.058426;\n")
        let result = CourseFile.load(text)
        XCTAssertEqual(result.problems, [], messages(result))
        XCTAssertEqual(result.course?.name, "Elm Street: Backyard")
        XCTAssertEqual(result.course?.holes[1].hazards[0].area.vertices.count, 4)
    }

    func testStrictNumbers() {
        XCTAssertEqual(CourseFile.decimal("-71.0589"), -71.0589)
        XCTAssertEqual(CourseFile.decimal(".5"), 0.5)
        for bad in ["nan", "inf", "-inf", "0x10", "1e3", "1.2.3", "", "-", ".", "1,5", "١٢"] {
            XCTAssertNil(CourseFile.decimal(bad), bad)
        }
        XCTAssertNil(CourseFile.point("91, 0"))
        XCTAssertNil(CourseFile.point("0, 181"))
        XCTAssertNil(CourseFile.point("1, 2, 3"))
        XCTAssertNil(CourseFile.integer("3.0"))
        XCTAssertNil(CourseFile.index("0"))
        XCTAssertNil(CourseFile.index("01"))
    }
}

final class CourseSafetyTests: XCTestCase {
    func testFiringPointNearTheBoundaryFailsTheFan() throws {
        // Move hole 1's firing point to 10 m short of its flag: the 105 yd fan now runs past the north boundary.
        let start = Geo.offset(GeoPoint(latitude: 42.360010, longitude: -71.059010), east: 58, north: 70)
        let text = try sample(replacing: "hole.1.firing_point.1: 42.360100, -71.058304",
                              with: String(format: "hole.1.firing_point.1: %.6f, %.6f", start.latitude, start.longitude))
        let result = CourseFile.load(text)
        XCTAssertNil(result.playableCourse)
        let fan = try XCTUnwrap(result.errors.first { $0.message.contains("safety fan") }, messages(result))
        XCTAssertEqual(fan.key, "hole.1.firing_point.1")
        XCTAssertEqual(fan.line, 17)
        XCTAssertTrue(fan.description.hasPrefix("Line 17: hole.1.firing_point.1: Hole 1, firing point 1: The safety fan"))
        // The course is still built so the app can show it alongside its problems.
        XCTAssertEqual(result.course?.holes.count, 2)
    }

    func testPointsOutsideTheBoundaryAndBeyond100Yards() throws {
        var text = try sample(replacing: "hole.1.flag.position: 42.360729, -71.058280",
                              with: "hole.1.flag.position: 42.362000, -71.058280")
        text = text.replacingOccurrences(of: "hole.2.firing_point.2: 42.360478, -71.058328",
                                         with: "hole.2.firing_point.2: 42.359000, -71.058328")
        let result = CourseFile.load(text)
        let all = messages(result)
        XCTAssertTrue(result.errors.contains { $0.key == "hole.1.flag.position" && $0.message.contains("flag is outside") }, all)
        XCTAssertTrue(result.errors.contains { $0.key == "hole.1.firing_point.1" && $0.message.contains("100 yd") }, all)
        XCTAssertTrue(result.errors.contains { $0.key == "hole.2.firing_point.2" && $0.message.contains("firing point is outside") }, all)
        XCTAssertTrue(result.errors.contains { $0.key == "hole.2.firing_point.2" && $0.message.contains("100 yd") }, all)
        // Hole 2's first firing point is untouched and still fine.
        XCTAssertFalse(result.problems.contains { $0.key == "hole.2.firing_point.1" }, all)
    }

    func testPoleHeightAndLeanRules() throws {
        var text = try sample(replacing: "hole.1.flag.pole_height_m: 2.438", with: "hole.1.flag.pole_height_m: 1.8")
        text = text.replacingOccurrences(of: "hole.2.flag.lean_deg: 0.2", with: "hole.2.flag.lean_deg: 0.5")
        let result = CourseFile.load(text)
        let all = messages(result)
        XCTAssertTrue(result.errors.contains { $0.key == "hole.1.flag.pole_height_m" && $0.message.contains("8 to 12 ft") }, all)
        XCTAssertTrue(result.errors.contains { $0.key == "hole.2.flag.lean_deg" && $0.message.contains("under 0.5°") }, all)
        XCTAssertEqual(result.errors.count, 2, all)

        for ok in ["2.438", "3.048", "3.658"] {
            let r = CourseFile.load(try sample(replacing: "hole.1.flag.pole_height_m: 2.438", with: "hole.1.flag.pole_height_m: \(ok)"))
            XCTAssertEqual(r.problems, [], "\(ok): \(messages(r))")
        }
    }

    func testValidatorRunsOnACourseBuiltInCode() {
        let corner = GeoPoint(latitude: 42.36, longitude: -71.06)
        let hole = Hole(number: 1, name: "Tiny", par: 3, firingPoints: [],
                        flag: Flag(position: Geo.offset(corner, east: 5, north: 5), poleHeightM: 2.438, leanDeg: 0.1))
        let course = Course(format: 1, id: "t", name: "T", version: 1, boundary: GeoPolygon([]), holes: [hole, hole])
        let problems = CourseValidator.problems(for: course)
        let text = problems.map(\.description).joined(separator: "\n")
        XCTAssertTrue(text.contains(SafetyReason.noBoundary.description), text)
        XCTAssertTrue(text.contains("Hole 1 appears twice"), text)
        XCTAssertTrue(text.contains("Hole 1 has no firing point"), text)
        // One boundary problem for the course, not one per firing point.
        XCTAssertEqual(problems.filter { $0.message == SafetyReason.noBoundary.description }.count, 1)
    }

    func testCourseRulesMatchTheModulesThatMeasureThem() {
        XCTAssertEqual(CourseRules.maxLeanDeg, LeanMath.limitDegrees)
        // The flag kit's 8, 10 and 12 ft poles all fit the allowed range.
        for feet in [8.0, 10, 12] { XCTAssertTrue(CourseRules.poleHeightRangeM.contains(feet * 0.3048)) }
    }
}
