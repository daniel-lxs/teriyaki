// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Chiaki",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Chiaki", path: "Sources/Chiaki")
    ]
)
