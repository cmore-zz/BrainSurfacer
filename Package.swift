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
        .library(name: "BrainSurfacerApple", targets: ["BrainSurfacerApple"]),
        .executable(
            name: "brainsurfacer-context",
            targets: ["BrainSurfacerContextCLI"]
        )
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
        .executableTarget(
            name: "BrainSurfacerContextCLI",
            dependencies: ["BrainSurfacerCore"]
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
            dependencies: [
                "BrainSurfacerCore",
                "BrainSurfacerFilesystem",
                "BrainSurfacerModel"
            ],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "BrainSurfacerAppleTests",
            dependencies: ["BrainSurfacerApple", "BrainSurfacerModel"]
        )
    ]
)
