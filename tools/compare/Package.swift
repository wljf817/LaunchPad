// swift-tools-version: 6.2

// Frame-by-frame comparison tooling: records the screen of the macOS 15
// reference VM and of the macOS 26 comparison VM, posts input that triggers a
// scene, adds a second display for the multi-display scenes, and compares two recordings. A separate package because the recorder must run on macOS 15,
// below the app's deployment target.

import PackageDescription

let package = Package(
    name: "FrameCompare",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "FrameCompare"
        ),
        .executableTarget(
            name: "frame-compare",
            dependencies: ["FrameCompare"]
        ),
        .executableTarget(
            name: "frame-record",
            dependencies: ["FrameCompare"]
        ),
        .executableTarget(
            name: "vm-input"
        ),
        .executableTarget(
            name: "virtual-display",
            linkerSettings: [.linkedFramework("CoreGraphics"), .linkedFramework("Foundation")]
        ),
        .testTarget(
            name: "FrameCompareTests",
            dependencies: ["FrameCompare"]
        ),
    ]
)
