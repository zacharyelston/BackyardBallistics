// swift-tools-version: 5.9
import PackageDescription

// Shared by SpudGunGolf and Squadz. No app, squad, scoring, safety or networking dependencies.
let package = Package(
    name: "GeoZones",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "CoreGeo", targets: ["CoreGeo"]), .library(name: "ZoneKit", targets: ["ZoneKit"]), .library(name: "ZoneMapKit", targets: ["ZoneMapKit"])],
    targets: [
        .target(name: "CoreGeo"),
        .target(name: "ZoneKit", dependencies: ["CoreGeo"]),
        .target(name: "ZoneMapKit", dependencies: ["CoreGeo", "ZoneKit"]),
        .testTarget(name: "ZoneKitTests", dependencies: ["CoreGeo", "ZoneKit"])
    ]
)
