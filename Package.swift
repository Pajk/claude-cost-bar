// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ClaudeCostBar",
    platforms: [.macOS(.v14)],
    products: [.library(name: "CostCore", targets: ["CostCore"]), .executable(name: "ClaudeCostBar", targets: ["ClaudeCostBar"])],
    targets: [
        .target(name: "CostCore"),
        .executableTarget(name: "ClaudeCostBar", dependencies: ["CostCore"]),
        .testTarget(name: "CostCoreTests", dependencies: ["CostCore"])
    ]
)
