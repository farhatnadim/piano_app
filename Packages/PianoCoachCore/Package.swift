// swift-tools-version:5.9
import PackageDescription

// Pure-Swift core of Piano Coach: music parsing, audio analysis, score following,
// adaptive pacing and voice-command parsing. Depends only on Foundation so the
// whole package builds and tests on Linux as well as on Apple platforms.
let package = Package(
    name: "PianoCoachCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PianoCoachCore", targets: ["PianoCoachCore"]),
    ],
    targets: [
        .target(name: "PianoCoachCore"),
        // Fixtures are read from disk by path (see TestSupport), not bundled as resources.
        .testTarget(name: "PianoCoachCoreTests", dependencies: ["PianoCoachCore"], exclude: ["Fixtures"]),
    ]
)
