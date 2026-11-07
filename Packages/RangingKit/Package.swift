// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RangingKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RangingKit", targets: ["RangingKit"])
    ],
    targets: [
        .target(name: "RangingKit"),
        .testTarget(name: "RangingKitTests", dependencies: ["RangingKit"])
    ]
)
