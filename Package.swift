// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "BrainSurfacer",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .library(name: "BrainSurfacerModel", targets: ["BrainSurfacerModel"]),
        .library(name: "BrainSurfacerCore", targets: ["BrainSurfacerCore"]),
        .library(name: "BrainSurfacerFilesystem", targets: ["BrainSurfacerFilesystem"]),
        .library(name: "BrainSurfacerApple", targets: ["BrainSurfacerApple"])
    ],
    targets: [
        .target(name: "BrainSurfacerModel"),
        .target(
            name: "BrainSurfacerCore",
            dependencies: ["BrainSurfacerModel"]
        ),
        .target(
            name: "BrainSurfacerFilesystem",
            dependencies: ["BrainSurfacerCore", "BrainSurfacerModel"]
        ),
        .target(
            name: "BrainSurfacerApple",
            dependencies: [
                "BrainSurfacerCore",
                "BrainSurfacerFilesystem",
                "BrainSurfacerModel"
            ]
        ),
        .testTarget(
            name: "BrainSurfacerCoreTests",
            dependencies: [
                "BrainSurfacerCore",
                "BrainSurfacerFilesystem",
                "BrainSurfacerModel"
            ]
        ),
        .testTarget(
            name: "BrainSurfacerFilesystemTests",
            dependencies: ["BrainSurfacerFilesystem", "BrainSurfacerModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BrainSurfacerAppleTests",
            dependencies: ["BrainSurfacerApple", "BrainSurfacerModel"]
        )
    ]
)
