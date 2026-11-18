// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "GameMetrikNative",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.executable(name: "GameMetrikNative", targets: ["GameMetrikNative"]),
               .library(name: "GameMetrikCore", targets: ["GameMetrikCore"])],
    targets: [
        .systemLibrary(name: "CZlib"),
        .target(name: "GameMetrikCore", dependencies: ["CZlib"]),
        .executableTarget(name: "GameMetrikNative", dependencies: ["GameMetrikCore"]),
        .testTarget(name: "GameMetrikSecurityTests", dependencies: ["GameMetrikNative", "GameMetrikCore"]),
        .testTarget(name: "GameMetrikCoreTests", dependencies: ["GameMetrikCore"], resources: [.copy("Fixtures")])
    ]
)
