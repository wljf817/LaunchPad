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
        // The launcher, LaunchPad.app's own executable (REF-DEV-013). Links no AppKit.
        .executableTarget(
            name: "LaunchPadLauncher"
        ),
        // Declarations of private system interfaces the original uses.
        .target(
            name: "LaunchPadPrivate",
            linkerSettings: [
                .linkedFramework("QuartzCore"),
                .linkedFramework("ApplicationServices"),
                // SLSTransaction* are only exported by the private SkyLight framework.
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight"]),
            ]
        ),
        .testTarget(
            name: "LaunchPadTests",
            dependencies: ["LaunchPad"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
