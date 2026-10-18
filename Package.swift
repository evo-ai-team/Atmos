// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Chosen",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ChosenCore", targets: ["ChosenCore"]), .executable(name: "Chosen", targets: ["Chosen"])],
    targets: [
        .target(name: "ChosenCore"),
        .executableTarget(name: "Chosen", dependencies: ["ChosenCore"]),
        .testTarget(name: "ChosenCoreTests", dependencies: ["ChosenCore"])
    ],
    swiftLanguageModes: [.v5]
)
