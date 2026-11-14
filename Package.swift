// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Metrolist",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Metrolist",
            path: "Sources/Metrolist",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
