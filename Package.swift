// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "lidless",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "lidless", targets: ["lidless"]),
    ],
    targets: [
        .target(name: "LidlessCore"),
        .executableTarget(name: "lidless", dependencies: ["LidlessCore"]),
        .testTarget(name: "LidlessCoreTests", dependencies: ["LidlessCore"]),
    ],
    swiftLanguageModes: [.v5]
)
