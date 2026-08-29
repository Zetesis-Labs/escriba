// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "jpr-transcribe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0")
    ],
    targets: [
        .target(name: "JPRCore"),
        .target(name: "JPRKit", dependencies: ["JPRCore"]),
        .target(
            name: "JPRWhisperKit",
            dependencies: [
                "JPRCore", "JPRKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ]),
        .executableTarget(
            name: "jpr-transcribe", dependencies: ["JPRKit", "JPRCore", "JPRWhisperKit"]),
        .executableTarget(
            name: "JPRMenuBar", dependencies: ["JPRKit", "JPRCore", "JPRWhisperKit"]),
        .testTarget(name: "JPRCoreTests", dependencies: ["JPRCore"]),
        .testTarget(name: "JPRKitTests", dependencies: ["JPRKit", "JPRCore"]),
        .testTarget(
            name: "JPRWhisperKitTests", dependencies: ["JPRWhisperKit", "JPRCore", "JPRKit"]),
    ]
)
