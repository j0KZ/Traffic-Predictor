// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "trafficlens",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TrafficCore", targets: ["TrafficCore"]),
        .executable(name: "trafficlens-cli", targets: ["trafficlens-cli"]),
        .executable(name: "TrafficLensApp", targets: ["TrafficLensApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
    ],
    targets: [
        .target(
            name: "TrafficCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .executableTarget(
            name: "trafficlens-cli",
            dependencies: [
                "TrafficCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(
            name: "TrafficLensApp",
            dependencies: ["TrafficCore"]
        ),
        .testTarget(
            name: "TrafficCoreTests",
            dependencies: ["TrafficCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
