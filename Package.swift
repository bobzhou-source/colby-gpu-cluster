// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ColbyGPUCluster",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "ColbyGPUCluster", targets: ["ColbyGPUCluster"]),
    ],
    targets: [
        .executableTarget(
            name: "ColbyGPUCluster",
            path: "Sources/ColbyGPUCluster"
        ),
        .testTarget(
            name: "ColbyGPUClusterTests",
            dependencies: ["ColbyGPUCluster"],
            path: "Tests/ColbyGPUClusterTests",
            resources: [.copy("Resources")]
        ),
    ]
)
