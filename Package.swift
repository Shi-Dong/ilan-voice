// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "IlanVoice",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "IlanVoice",
            path: "Sources/IlanVoice"
        ),
    ]
)
