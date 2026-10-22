// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7"),
    ],
    targets: [
        .executableTarget(
            name: "CallRecorder",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/CallRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
