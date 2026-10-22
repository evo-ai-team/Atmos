// swift-tools-version: 6.2
import PackageDescription

// Directory guides are for maintainers, not runtime resources. Listing them
// explicitly also keeps SwiftPM from warning about unhandled Markdown files.
let coreDomains = ["Accessibility", "Actions", "Diagnostics", "Inference", "Session", "Speech", "Usage"]
let appDomains = ["Application", "ComputerControl", "Diagnostics", "Interface", "Interface/Notch", "Interface/Settings", "Security", "Speech"]

func documentation(in domains: [String]) -> [String] {
    ["README.md"] + domains.map { "\($0)/README.md" }
}

let package = Package(
    name: "Mouse",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MouseCore", targets: ["MouseCore"]),
        .executable(name: "Mouse", targets: ["Mouse"])
    ],
    targets: [
        .target(name: "MouseCore", exclude: documentation(in: coreDomains)),
        .executableTarget(name: "Mouse", dependencies: ["MouseCore"], exclude: documentation(in: appDomains)),
        .testTarget(name: "MouseCoreTests", dependencies: ["MouseCore"], exclude: documentation(in: coreDomains))
    ],
    swiftLanguageModes: [.v5]
)
