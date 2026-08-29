// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jpr-transcribe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "JPRCore"),
        .target(name: "JPRKit", dependencies: ["JPRCore"]),
        .executableTarget(name: "jpr-transcribe", dependencies: ["JPRKit", "JPRCore"]),
        .executableTarget(name: "JPRMenuBar", dependencies: ["JPRKit", "JPRCore"]),
        .testTarget(name: "JPRCoreTests", dependencies: ["JPRCore"]),
        .testTarget(name: "JPRKitTests", dependencies: ["JPRKit", "JPRCore"]),
    ]
)
