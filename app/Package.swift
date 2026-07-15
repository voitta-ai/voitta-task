// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VoittaTask",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "VoittaTask",
            path: "Sources/VoittaTask",
            resources: [.copy("Resources/voitta-dog.png")]
        )
    ]
)
