// swift-tools-version: 6.2
import PackageDescription

// Los plugins son reactores WASI: se instancian una vez y atienden llamadas por escriba_handle.
let pluginLinkerSettings: [LinkerSetting] = [
    .unsafeFlags(
        ["-Xclang-linker", "-mexec-model=reactor", "-Xlinker", "--export=escriba_handle"],
        .when(platforms: [.wasi]))
]

let package = Package(
    name: "escriba",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
        .package(url: "https://github.com/swiftwasm/WasmKit.git", .upToNextMinor(from: "0.4.1")),
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
        .target(name: "EscribaOKF", dependencies: ["EscribaCore", "EscribaEngine"]),
        .target(name: "EscribaIntelligence", dependencies: ["EscribaCore", "EscribaEngine"]),
        .target(name: "EscribaOpenAI", dependencies: ["EscribaCore", "EscribaEngine"]),
        .target(
            name: "EscribaPluginKit", dependencies: ["EscribaCore"],
            swiftSettings: [.enableExperimentalFeature("Extern")]),
        .target(
            name: "EscribaPlugins",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaPluginKit",
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
            ]),
        .executableTarget(
            name: "escriba-plugin-okf",
            dependencies: ["EscribaCore", "EscribaEngine", "EscribaOKF", "EscribaPluginKit"],
            linkerSettings: pluginLinkerSettings),
        .executableTarget(
            name: "escriba-plugin-notion",
            dependencies: ["EscribaCore", "EscribaEngine", "EscribaNotion", "EscribaPluginKit"],
            linkerSettings: pluginLinkerSettings),
        .target(
            name: "EscribaModel",
            dependencies: [
                "EscribaCore", "EscribaEngine", "EscribaSystemKit", "EscribaStore", "EscribaNotion",
                "EscribaOKF", "EscribaOpenAI", "EscribaPluginKit", "EscribaPlugins",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(
            name: "escriba-wasm-probe",
            dependencies: ["EscribaCore", "EscribaEngine", "EscribaNotion", "EscribaOKF"]),
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
                "EscribaModel", "EscribaNotion", "EscribaOKF", "EscribaIntelligence", "EscribaOpenAI",
                "EscribaPluginKit", "EscribaPlugins",
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
            name: "EscribaOKFTests", dependencies: ["EscribaOKF", "EscribaCore", "EscribaEngine"]),
        .testTarget(
            name: "EscribaOpenAITests", dependencies: ["EscribaOpenAI", "EscribaCore", "EscribaEngine"]),
        .testTarget(
            name: "EscribaPluginsTests",
            dependencies: [
                "EscribaPlugins", "EscribaPluginKit", "EscribaCore", "EscribaEngine",
                .product(name: "WAT", package: "WasmKit"),
            ]),
        .testTarget(
            name: "EscribaIntelligenceTests",
            dependencies: ["EscribaIntelligence", "EscribaCore", "EscribaEngine"]),
        .testTarget(
            name: "EscribaStoreTests",
            dependencies: ["EscribaStore", "EscribaCore", "EscribaEngine", "EscribaSystemKit"]),
        .testTarget(
            name: "EscribaModelTests",
            dependencies: [
                "EscribaModel", "EscribaStore", "EscribaCore", "EscribaNotion", "EscribaOKF", "EscribaSystemKit",
                "EscribaPluginKit", "EscribaPlugins",
            ],
            swiftSettings: [.defaultIsolation(MainActor.self)]),
    ]
)
