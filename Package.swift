// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "lidsomnia",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lidsomnia", targets: ["lidsomnia"]),
    ],
    targets: [
        .target(name: "LidsomniaCore"),
        .executableTarget(name: "lidsomnia", dependencies: ["LidsomniaCore"]),
        .testTarget(name: "LidsomniaCoreTests", dependencies: ["LidsomniaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
