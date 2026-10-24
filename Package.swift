// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BensVoice",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "BensVoice",
            path: "Sources/BensVoice",
            swiftSettings: [.unsafeFlags(["-Osize"])]
        )
    ]
)
