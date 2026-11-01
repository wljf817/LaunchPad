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
                .linkedFramework("CoreText"),
                // SLSTransaction* are only exported by the private SkyLight framework,
                // the icon functions and classes by the private IconServices framework.
                .unsafeFlags(["-F/System/Library/PrivateFrameworks", "-framework", "SkyLight", "-framework", "IconServices"]),
            ]
        ),
        // The text input service, an XPC service in the background process's bundle (REF-SEARCH-011).
        .executableTarget(
            name: "LaunchPadECTI",
            dependencies: ["LaunchPadECTIPrivate"],
            // MainMenu.xib is compiled into the service's bundle by scripts/build-app.sh.
            exclude: ["Resources"]
        ),
        // Declarations of private system interfaces the original service uses.
        .target(
            name: "LaunchPadECTIPrivate",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreText"),
            ]
        ),
        .testTarget(
            name: "LaunchPadTests",
            dependencies: ["LaunchPad"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "LaunchPadECTITests",
            dependencies: ["LaunchPadECTI"]
        ),
    ]
)
