// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LaunchPad",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "LaunchPad"
        ),
        .testTarget(
            name: "LaunchPadTests",
            dependencies: ["LaunchPad"]
        ),
    ]
)
