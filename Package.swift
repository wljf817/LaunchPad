// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "LaunchPad",
    platforms: [
        .macOS(.v26)
    ],
    targets: [
        .executableTarget(
            name: "LaunchPad",
            dependencies: ["LaunchPadPrivate"],
            // Copied into LaunchPad.app/Contents/Resources by scripts/build-app.sh,
            // where the app reads it like Dock reads its own copy.
            exclude: ["Resources"]
        ),
        // Declarations of private system interfaces the original uses.
        .target(
            name: "LaunchPadPrivate"
        ),
        .testTarget(
            name: "LaunchPadTests",
            dependencies: ["LaunchPad"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
