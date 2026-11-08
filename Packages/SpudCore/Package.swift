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
//   RoundKit   – fire missions per hole, cease fire and verify, downrange play, scoring, practice
//   GroupKit   – v3 Squadz: the squad and match protocol, the commander's and match host's state, holds
//   GroupLink  – GroupKit over the local network: Bonjour, TLS keyed from the join code (Network.framework)
let package = Package(
    name: "SpudCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CoreGeo", targets: ["CoreGeo"]),
        .library(name: "SafetyKit", targets: ["SafetyKit"]),
        .library(name: "RangingKit", targets: ["RangingKit"]),
        .library(name: "BallisticsKit", targets: ["BallisticsKit"]),
        .library(name: "CourseKit", targets: ["CourseKit"]),
        .library(name: "RoundKit", targets: ["RoundKit"]),
        .library(name: "GroupKit", targets: ["GroupKit"]),
        .library(name: "GroupLink", targets: ["GroupLink"])
    ],
    targets: [
        .target(name: "CoreGeo"),
        .target(name: "SafetyKit", dependencies: ["CoreGeo"], resources: [.copy("safety-limits.json")]),
        .target(name: "RangingKit", dependencies: ["CoreGeo"]),
        .target(name: "BallisticsKit", dependencies: ["SafetyKit"]),
        .target(name: "CourseKit", dependencies: ["CoreGeo", "SafetyKit"]),
        .target(name: "RoundKit", dependencies: ["CoreGeo", "RangingKit", "BallisticsKit", "CourseKit"]),
        .target(name: "GroupKit", dependencies: ["CoreGeo", "SafetyKit", "RangingKit", "CourseKit", "RoundKit"]),
        .target(name: "GroupLink", dependencies: ["GroupKit"]),
        .testTarget(name: "CoreGeoTests", dependencies: ["CoreGeo"]),
        .testTarget(name: "SafetyKitTests", dependencies: ["SafetyKit", "CoreGeo"]),
        .testTarget(name: "RangingKitTests", dependencies: ["RangingKit", "CoreGeo"]),
        .testTarget(name: "BallisticsKitTests", dependencies: ["BallisticsKit", "SafetyKit"], resources: [.copy("prototype-reference.json")]),
        // RangingKit is here only to pin CourseRules.maxLeanDeg to LeanMath.limitDegrees.
        .testTarget(name: "CourseKitTests", dependencies: ["CourseKit", "CoreGeo", "SafetyKit", "RangingKit"]),
        .testTarget(name: "RoundKitTests", dependencies: ["RoundKit", "RangingKit", "BallisticsKit", "CourseKit", "CoreGeo"]),
        .testTarget(name: "GroupKitTests", dependencies: ["GroupKit", "RoundKit", "RangingKit", "BallisticsKit", "CourseKit", "SafetyKit", "CoreGeo"]),
        .testTarget(name: "GroupLinkTests", dependencies: ["GroupLink", "GroupKit", "CourseKit", "CoreGeo"])
    ]
)
