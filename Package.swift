// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AppMan",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "AppManCore", targets: ["AppManCore"]),
        .executable(name: "AppMan", targets: ["AppManApp"])
    ],
    targets: [
        .target(name: "AppManCore"),
        .executableTarget(
            name: "AppManApp",
            dependencies: ["AppManCore"]
        ),
        .testTarget(
            name: "AppManCoreTests",
            dependencies: ["AppManCore"],
            resources: [
                .copy("Fixtures")
            ]
        ),
        .testTarget(
            name: "AppManAppTests",
            dependencies: ["AppManApp", "AppManCore"]
        )
    ]
)
