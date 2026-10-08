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
        .target(name: "EscribaIntelligence", dependencies: ["EscribaCore", "EscribaEngine"]),
        .target(name: "EscribaOpenAI", dependencies: ["EscribaCore", "EscribaEngine"]),
        .target(name: "EscribaJSC", dependencies: ["EscribaCore", "EscribaEngine"], resources: [.copy("Resources/conectores")]),
        .target(
            name: "EscribaModel",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaSystemKit", "EscribaStore",
                "EscribaOpenAI",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
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
                "EscribaModel", "EscribaIntelligence", "EscribaOpenAI",
                "EscribaJSC",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(
            name: "EscribaNativeHost",
            dependencies: ["EscribaCore", "EscribaEngine", "EscribaWhisper", "EscribaIntelligence"],
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
            name: "EscribaOpenAITests", dependencies: ["EscribaOpenAI", "EscribaCore", "EscribaEngine"]),
        .testTarget(name: "EscribaJSCTests", dependencies: ["EscribaJSC", "EscribaCore", "EscribaEngine"]),
        .testTarget(
            name: "EscribaIntelligenceTests",
            dependencies: ["EscribaIntelligence", "EscribaCore", "EscribaEngine"]),
        .testTarget(
            name: "EscribaStoreTests",
            dependencies: ["EscribaStore", "EscribaCore", "EscribaEngine", "EscribaSystemKit"]),
        .testTarget(
            name: "EscribaModelTests",
            dependencies: [
                "EscribaModel", "EscribaStore", "EscribaCore", "EscribaSystemKit", "EscribaJSC",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(
            name: "EscribaNativeHostTests",
            dependencies: ["EscribaNativeHost", "EscribaCore"],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
