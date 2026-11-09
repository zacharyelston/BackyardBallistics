import Foundation
import CoreGeo
import SafetyKit
import RangingKit
import CourseKit
import RoundKit
import GroupKit

// spud-docs: prints the facts the How to Play docs quote, read from the real modules, as JSON.
// scripts/build-howto.sh renders docs/howto from these, so the docs can't drift from the code.
//
//   swift run --package-path Packages/SpudCore spud-docs [path/to/course.yaml]

let limits = Safety.limits

func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

var facts: [String: Any] = [
    "safety": [
        "version": limits.version,
        "maxSolutionRangeM": round1(limits.maxSolutionRange),
        "maxSolutionRangeYd": Int((limits.maxSolutionRange / 0.9144).rounded()),
        "maxMuzzleVelocityMS": limits.maxMuzzleVelocity,
        "flagGateToleranceM": limits.flagGateTolerance,
        "fanRangeM": round1(limits.fanRange),
        "fanRangeYd": Int((limits.fanRange / 0.9144).rounded()),
        "fanHalfAngleDeg": limits.fanHalfAngle,
        "downrangePrompt": DownrangeLog.prompt,
    ],
    "rules": [
        "maxRoundsPerHole": HoleRules.maxRoundsPerHole,
        "preferAdvanceGainM": HoleRules.preferAdvanceGain,
        "scoreExample": ["rounds": 3, "closestM": 2.4, "inRadiusM": 1.0,
                         "score": HoleRules.score(rounds: 3, closest: 2.4, inRadius: 1.0)],
        "fireControlMinStepM": FireControl.minimumStep,
        "fireControlStepAt30m": FireControl.initialStep(range: 30),
        "fireControlStepAt60m": FireControl.initialStep(range: 60),
        "rangeCalls": RangeCall.allCases.map(\.label),
    ],
    "flags": [
        "poleHeightMinM": CourseRules.poleHeightRangeM.lowerBound,
        "poleHeightMaxM": CourseRules.poleHeightRangeM.upperBound,
        "maxLeanDeg": CourseRules.maxLeanDeg,
        "defaultRingM": Flag.defaultInRadiusM,
        "maxRingM": CourseRules.maxInRadiusM,
    ],
    "squadz": [
        "protocolVersion": GroupProtocol.version,
        "positionTimeoutS": SquadHost.positionTimeout,
        "orderMaxText": Order.maxText,
        "orders": Order.Kind.allCases.map { ["kind": $0.rawValue, "title": $0.title] },
        "orderAnswers": OrderAck.Response.allCases.map(\.rawValue),
        "lockPurposes": LockPurpose.allCases.map(\.rawValue),
        "holds": [Hold.walkingOut, .checkFire(by: "Ben"),
                  .memberInFan(MemberID(), name: "Ben"), .positionUnknown(MemberID(), name: "Ben")]
            .map(\.description),
    ],
]

// The sample course (or the one given), for the field picture and an example hole.
let coursePath = CommandLine.arguments.dropFirst().first ?? "courses/sample-course.yaml"
if let data = FileManager.default.contents(atPath: coursePath), let course = CourseFile.load(data: data).course,
   let hole = course.holes.first, let fp = hole.firingPoints.first {
    let problems = CourseValidator.problems(for: course).filter { $0.severity == .error }
    func en(_ p: GeoPoint) -> [Double] { let e = Geo.eastNorth(of: p, from: fp); return [round1(e.east), round1(e.north)] }
    facts["course"] = [
        "name": course.name,
        "holes": course.holes.count,
        "totalPar": course.totalPar,
        "valid": problems.isEmpty,
        "hole": [
            "number": hole.number, "name": hole.name, "par": hole.par,
            "distanceM": round1(Geo.distance(fp, hole.flag.position)),
            "bearingDeg": round1(Geo.bearing(from: fp, to: hole.flag.position)),
            "ringM": hole.flag.inRadiusM,
            "poleHeightM": hole.flag.poleHeightM,
            // Metres east/north of the firing point, for the picture.
            "flagEN": en(hole.flag.position),
            "boundaryEN": course.boundary.vertices.map(en),
        ],
    ]
} else {
    FileHandle.standardError.write(Data("spud-docs: couldn't read a course at \(coursePath)\n".utf8))
    exit(1)
}

let json = try JSONSerialization.data(withJSONObject: facts, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(json)
FileHandle.standardOutput.write(Data("\n".utf8))
