// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Murmure",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Murmure",
            path: "Sources/Murmure",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
