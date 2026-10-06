// swift-tools-version: 6.2
import PackageDescription

let api = Context.packageDirectory + "/wasmtime-c-api"

let package = Package(
    name: "wtprobe", platforms: [.macOS(.v26)],
    targets: [
        .systemLibrary(name: "CWasmtime", path: "Sources/CWasmtime"),
        .executableTarget(
            name: "wtprobe", dependencies: ["CWasmtime"],
            swiftSettings: [.unsafeFlags(["-I", api + "/include"])],
            linkerSettings: [.unsafeFlags(["-L", api + "/lib", "-Xlinker", "-rpath", "-Xlinker", api + "/lib"])]),
    ])
