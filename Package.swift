// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Interval",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Interval", targets: ["Pause"])],
    targets: [
        .target(name: "PauseCore"),
        .executableTarget(name: "Pause", dependencies: ["PauseCore"]),
        .testTarget(name: "PauseCoreTests", dependencies: ["PauseCore"]),
        .testTarget(name: "PauseTests", dependencies: ["Pause", "PauseCore"])
    ],
    swiftLanguageModes: [.v5]
)
