// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "jpr-transcribe",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "JPRCore"),
        .target(name: "JPRKit", dependencies: ["JPRCore"]),
        .target(
            name: "JPRWhisperKit",
            dependencies: [
                "JPRCore", "JPRKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]),
        .target(
            name: "JPRStore",
            dependencies: [
                "JPRCore", "JPRKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]),
        .executableTarget(
            name: "jpr-transcribe",
            dependencies: ["JPRKit", "JPRCore", "JPRWhisperKit", "JPRStore"]),
        .executableTarget(
            name: "JPRMenuBar",
            dependencies: ["JPRKit", "JPRCore", "JPRWhisperKit", "JPRStore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "JPRCoreTests", dependencies: ["JPRCore"]),
        .testTarget(name: "JPRKitTests", dependencies: ["JPRKit", "JPRCore"]),
        .testTarget(
            name: "JPRWhisperKitTests", dependencies: ["JPRWhisperKit", "JPRCore", "JPRKit"]),
        .testTarget(name: "JPRStoreTests", dependencies: ["JPRStore", "JPRCore", "JPRKit"]),
    ]
)
