// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "CallRecorder",
            path: "Sources/CallRecorder",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
