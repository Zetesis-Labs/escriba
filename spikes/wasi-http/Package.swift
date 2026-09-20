// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "probe",
    targets: [
        .target(name: "CWasiHttp"),
        .executableTarget(name: "probe", dependencies: ["CWasiHttp"]),
    ])
