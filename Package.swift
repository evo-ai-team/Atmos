// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Mouse",
    platforms: [.macOS(.v26)],
    products: [.library(name: "MouseCore", targets: ["MouseCore"]), .executable(name: "Mouse", targets: ["Mouse"])],
    targets: [
        .target(name: "MouseCore"),
        .executableTarget(name: "Mouse", dependencies: ["MouseCore"]),
        .testTarget(name: "MouseCoreTests", dependencies: ["MouseCore"])
    ],
    swiftLanguageModes: [.v5]
)
