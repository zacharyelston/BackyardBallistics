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
//   GroupKit   – v3 Squadz: the squad protocol, the commander's state, holds
//   FieldKit   – the field in 3D: ENU frames, georeferencing reconstructions to GPS, elevation grids, mesh records
//   TheaterKit – the Theater host's door for phones: fields, notes and files, saved per field
//   GroupLink  – GroupKit over the local network: Bonjour, TLS keyed from the join code (Network.framework)
//   FieldCapture – photos to a georeferenced field mesh, minus RealityKit: EXIF GPS, camera pairing, the fit
let package = Package(
    name: "SpudCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SafetyKit", targets: ["SafetyKit"]),
        .library(name: "RangingKit", targets: ["RangingKit"]),
        .library(name: "BallisticsKit", targets: ["BallisticsKit"]),
        .library(name: "CourseKit", targets: ["CourseKit"]),
        .library(name: "RoundKit", targets: ["RoundKit"]),
        .library(name: "GroupKit", targets: ["GroupKit"]),
        // Prints the facts docs/howto quotes, from the real modules (scripts/build-howto.sh).
        .executable(name: "spud-docs", targets: ["SpudDocs"]),
        .library(name: "GroupLink", targets: ["GroupLink"]),
        .library(name: "FieldKit", targets: ["FieldKit"]),
        .library(name: "TheaterKit", targets: ["TheaterKit"]),
        .library(name: "FieldCapture", targets: ["FieldCapture"]),
        // Photos of a course to a georeferenced mesh for the Theater host (macOS only; docs/MESHING.md).
        .executable(name: "spud-mesh", targets: ["SpudMesh"])
    ],
    dependencies: [.package(path: "../GeoZones")],
    targets: [
        .target(name: "SafetyKit", dependencies: [.product(name: "CoreGeo", package: "GeoZones")], resources: [.copy("safety-limits.json")]),
        .target(name: "RangingKit", dependencies: [.product(name: "CoreGeo", package: "GeoZones")]),
        .target(name: "BallisticsKit", dependencies: ["SafetyKit"]),
        .target(name: "CourseKit", dependencies: [.product(name: "CoreGeo", package: "GeoZones"), "SafetyKit"]),
        .target(name: "RoundKit", dependencies: [.product(name: "CoreGeo", package: "GeoZones"), "RangingKit", "BallisticsKit", "CourseKit"]),
        .target(name: "GroupKit", dependencies: [.product(name: "CoreGeo", package: "GeoZones"), "SafetyKit", "RangingKit", "CourseKit", "RoundKit"]),
        .executableTarget(name: "SpudDocs", dependencies: [.product(name: "CoreGeo", package: "GeoZones"), "SafetyKit", "RangingKit", "CourseKit", "RoundKit", "GroupKit"]),
        .target(name: "GroupLink", dependencies: ["GroupKit"]),
        .target(name: "FieldKit", dependencies: [.product(name: "CoreGeo", package: "GeoZones"), "CourseKit"]),
        .target(name: "TheaterKit", dependencies: ["GroupKit", "FieldKit", "CourseKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .target(name: "FieldCapture", dependencies: ["FieldKit", "CourseKit", .product(name: "CoreGeo", package: "GeoZones")]),
        // RealityKit's PhotogrammetrySession; the sources are `#if os(macOS)`, an iOS build gets a stub.
        .executableTarget(name: "SpudMesh", dependencies: ["FieldCapture", "FieldKit", "CourseKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "CoreGeoTests", dependencies: [.product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "SafetyKitTests", dependencies: ["SafetyKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "RangingKitTests", dependencies: ["RangingKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "BallisticsKitTests", dependencies: ["BallisticsKit", "SafetyKit"], resources: [.copy("prototype-reference.json")]),
        // RangingKit is here only to pin CourseRules.maxLeanDeg to LeanMath.limitDegrees.
        .testTarget(name: "CourseKitTests", dependencies: ["CourseKit", .product(name: "CoreGeo", package: "GeoZones"), "SafetyKit", "RangingKit"]),
        .testTarget(name: "RoundKitTests", dependencies: ["RoundKit", "RangingKit", "BallisticsKit", "CourseKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "GroupKitTests", dependencies: ["GroupKit", "RoundKit", "RangingKit", "BallisticsKit", "CourseKit", "SafetyKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "TheaterKitTests", dependencies: ["TheaterKit", "GroupKit", "FieldKit", "CourseKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "FieldKitTests", dependencies: ["FieldKit", .product(name: "CoreGeo", package: "GeoZones"), "CourseKit"]),
        .testTarget(name: "FieldCaptureTests", dependencies: ["FieldCapture", "FieldKit", "CourseKit", .product(name: "CoreGeo", package: "GeoZones")]),
        .testTarget(name: "GroupLinkTests", dependencies: ["GroupLink", "GroupKit", "CourseKit", .product(name: "CoreGeo", package: "GeoZones"), "TheaterKit", "FieldKit"])
    ]
)
