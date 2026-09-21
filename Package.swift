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
        .target(name: "EscribaEngine", dependencies: ["EscribaCore"]),
        .systemLibrary(name: "CSQLite", providers: [.apt(["libsqlite3-dev"])]),
        .target(
            name: "EscribaSystemKit",
            dependencies: [
                "EscribaCore", "EscribaEngine",
                .target(name: "CSQLite", condition: .when(platforms: [.linux])),
            ]),
        .target(
            name: "EscribaWhisper",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaSystemKit",
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ]),
        .target(
            name: "EscribaStore",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaSystemKit",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]),
        .target(name: "EscribaNotion", dependencies: ["EscribaCore", "EscribaEngine"]),
        .target(name: "EscribaIntelligence", dependencies: ["EscribaCore", "EscribaEngine"]),
        .target(
            name: "EscribaModel",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaSystemKit", "EscribaStore", "EscribaNotion",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(
            name: "escriba-wasm-probe", dependencies: ["EscribaCore", "EscribaEngine", "EscribaNotion"]),
        .executableTarget(
            name: "escriba",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaSystemKit", "EscribaWhisper", "EscribaStore",
                "EscribaIntelligence",
            ]),
        .executableTarget(
            name: "EscribaMenuBar",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaSystemKit", "EscribaWhisper", "EscribaStore",
                "EscribaModel", "EscribaNotion", "EscribaIntelligence",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "EscribaCoreTests", dependencies: ["EscribaCore"]),
        .testTarget(name: "EscribaEngineTests", dependencies: ["EscribaEngine", "EscribaCore"]),
        .testTarget(
            name: "EscribaSystemKitTests",
            dependencies: ["EscribaSystemKit", "EscribaEngine", "EscribaCore"]),
        .testTarget(
            name: "EscribaWhisperTests",
            dependencies: ["EscribaWhisper", "EscribaCore", "EscribaEngine", "EscribaSystemKit"]),
        .testTarget(
            name: "EscribaNotionTests", dependencies: ["EscribaNotion", "EscribaCore", "EscribaEngine"]),
        .testTarget(
            name: "EscribaIntelligenceTests",
            dependencies: ["EscribaIntelligence", "EscribaCore", "EscribaEngine"]),
        .testTarget(
            name: "EscribaStoreTests",
            dependencies: ["EscribaStore", "EscribaCore", "EscribaEngine", "EscribaSystemKit"]),
        .testTarget(
            name: "EscribaModelTests",
            dependencies: ["EscribaModel", "EscribaStore", "EscribaCore", "EscribaNotion"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
