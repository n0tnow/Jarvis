// swift-tools-version:5.9
import PackageDescription

// JARVIS — native macOS foundation. Zero external dependencies.
// Built with SwiftPM because the dev machine has Command Line Tools only (no Xcode).
// `scripts/build_app.sh` wraps the executable into Jarvis.app.
let package = Package(
    name: "Jarvis",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Jarvis",
            path: "Sources/Jarvis"
        ),
        .testTarget(
            name: "JarvisTests",
            dependencies: ["Jarvis"],
            path: "Tests/JarvisTests"
        ),
    ]
)
