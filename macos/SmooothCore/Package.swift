// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SmooothCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SmooothCore", targets: ["SmooothCore"]),
    ],
    targets: [
        .target(name: "SmooothCore"),
        .testTarget(
            name: "SmooothCoreTests",
            dependencies: ["SmooothCore"],
            resources: [.copy("Fixtures/vectors.json")]
        ),
    ]
)
