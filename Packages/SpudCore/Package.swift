// swift-tools-version: 5.9
import PackageDescription

// SpudCore: the app's platform-free logic, testable on a Mac.
//
// Dependency order (each module may use only the ones above it):
//   CoreGeo    – GPS points, local east/north offsets, polygons
//   SafetyKit  – every safety limit and check; nothing below may bypass it
//   RangingKit – reticle (stadia) ranging, spotting model, camera rays, lean, pole height, multi-photo cross-check
//   BallisticsKit – flight, roll-out and the firing solver; limits come from SafetyKit
//   CourseKit  – course files: parsing, the Course/Hole model, validation through SafetyKit
let package = Package(
    name: "SpudCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoreGeo", targets: ["CoreGeo"]),
        .library(name: "SafetyKit", targets: ["SafetyKit"]),
        .library(name: "RangingKit", targets: ["RangingKit"]),
        .library(name: "BallisticsKit", targets: ["BallisticsKit"]),
        .library(name: "CourseKit", targets: ["CourseKit"])
    ],
    targets: [
        .target(name: "CoreGeo"),
        .target(name: "SafetyKit", dependencies: ["CoreGeo"], resources: [.copy("safety-limits.json")]),
        .target(name: "RangingKit", dependencies: ["CoreGeo"]),
        .target(name: "BallisticsKit", dependencies: ["SafetyKit"]),
        .target(name: "CourseKit", dependencies: ["CoreGeo", "SafetyKit"]),
        .testTarget(name: "CoreGeoTests", dependencies: ["CoreGeo"]),
        .testTarget(name: "SafetyKitTests", dependencies: ["SafetyKit", "CoreGeo"]),
        .testTarget(name: "RangingKitTests", dependencies: ["RangingKit", "CoreGeo"]),
        .testTarget(name: "BallisticsKitTests", dependencies: ["BallisticsKit", "SafetyKit"], resources: [.copy("prototype-reference.json")]),
        // RangingKit is here only to pin CourseRules.maxLeanDeg to LeanMath.limitDegrees.
        .testTarget(name: "CourseKitTests", dependencies: ["CourseKit", "CoreGeo", "SafetyKit", "RangingKit"])
    ]
)
