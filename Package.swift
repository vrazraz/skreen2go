// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Skreen2Go",
    // Required before a target may carry localized resources.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Skreen2Go", targets: ["Skreen2Go"])
    ],
    targets: [
        .target(
            name: "Skreen2GoCore",
            path: "Sources/Skreen2GoCore",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "Skreen2Go",
            dependencies: ["Skreen2GoCore"],
            path: "Sources/Skreen2Go"
        ),
        .testTarget(
            name: "Skreen2GoCoreTests",
            dependencies: ["Skreen2GoCore"],
            path: "Tests/Skreen2GoCoreTests"
        )
    ],
    swiftLanguageVersions: [.v5]
)
