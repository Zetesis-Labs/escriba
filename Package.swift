// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "escriba",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(name: "EscribaCore"),
        .target(name: "EscribaKit", dependencies: ["EscribaCore"]),
        .target(
            name: "EscribaWhisper",
            dependencies: [
                "EscribaCore", "EscribaKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]),
        .target(
            name: "EscribaStore",
            dependencies: [
                "EscribaCore", "EscribaKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]),
        .target(
            name: "EscribaModel",
            dependencies: ["EscribaCore", "EscribaKit", "EscribaStore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(
            name: "escriba",
            dependencies: ["EscribaKit", "EscribaCore", "EscribaWhisper", "EscribaStore"]),
        .executableTarget(
            name: "EscribaMenuBar",
            dependencies: ["EscribaKit", "EscribaCore", "EscribaWhisper", "EscribaStore", "EscribaModel"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "EscribaCoreTests", dependencies: ["EscribaCore"]),
        .testTarget(name: "EscribaKitTests", dependencies: ["EscribaKit", "EscribaCore"]),
        .testTarget(
            name: "EscribaWhisperTests", dependencies: ["EscribaWhisper", "EscribaCore", "EscribaKit"]),
        .testTarget(name: "EscribaStoreTests", dependencies: ["EscribaStore", "EscribaCore", "EscribaKit"]),
        .testTarget(
            name: "EscribaModelTests",
            dependencies: ["EscribaModel", "EscribaStore", "EscribaCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
