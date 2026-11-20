// swift-tools-version: 6.2
import PackageDescription

// Directory guides are for maintainers, not runtime resources. Listing them
// explicitly also keeps SwiftPM from warning about unhandled Markdown files.
let coreDomains = ["Accessibility", "Actions", "Diagnostics", "Inference", "Session", "Speech", "Usage"]
let appDomains = ["Application", "ComputerControl", "Diagnostics", "Diagnostics/Benchmark", "Interface", "Interface/Notch", "Interface/Settings", "Security", "Speech"]

func documentation(in domains: [String]) -> [String] {
    ["README.md"] + domains.map { "\($0)/README.md" }
}

let package = Package(
    name: "Atmos",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "AtmosCore", targets: ["AtmosCore"]),
        .executable(name: "Atmos", targets: ["Atmos"])
    ],
    targets: [
        .target(name: "AtmosCore", exclude: documentation(in: coreDomains)),
        .executableTarget(name: "Atmos", dependencies: ["AtmosCore"], exclude: documentation(in: appDomains)),
        .testTarget(name: "AtmosCoreTests", dependencies: ["AtmosCore"], exclude: documentation(in: coreDomains))
    ],
    swiftLanguageModes: [.v5]
)
