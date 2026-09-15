// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RecallCapture",
    defaultLocalization: "ja",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "CaptureCore", targets: ["CaptureCore"]),
        .executable(name: "RecallCapture", targets: ["RecallCapture"])
    ],
    targets: [
        .target(name: "CaptureCore"),
        .executableTarget(
            name: "RecallCapture",
            dependencies: ["CaptureCore"]
        ),
        .testTarget(
            name: "CaptureCoreTests",
            dependencies: ["CaptureCore"]
        )
    ]
)
