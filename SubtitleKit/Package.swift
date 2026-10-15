// swift-tools-version: 6.0

import PackageDescription

/// Platform-neutral subtitle parsing and rasterization (Foundation, CoreGraphics, CoreText only)
/// so the parsers and renderer run under `swift test` on macOS as well as inside the app.
let package = Package(
    name: "SubtitleKit",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v14),
    ],
    products: [
        .library(name: "SubtitleKit", targets: ["SubtitleKit"]),
    ],
    targets: [
        .target(name: "SubtitleKit"),
        .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"]),
    ],
    swiftLanguageModes: [.v5]
)
