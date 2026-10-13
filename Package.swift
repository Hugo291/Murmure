// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Murmure",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Parakeet TDT v3 (NVIDIA) en Core ML sur le Neural Engine — moteur de transcription rapide.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "Murmure",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/Murmure",
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
