// swift-tools-version: 5.8
import PackageDescription

let package = Package(
    name: "VibeWave",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "VibeWave", targets: ["VibeWave"])],
    targets: [
        .target(name: "VibeWaveCore"),
        .executableTarget(name: "VibeWave", dependencies: ["VibeWaveCore"]),
        .testTarget(name: "VibeWaveCoreTests", dependencies: ["VibeWaveCore"])
    ]
)
