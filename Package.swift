// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "IlanVoice",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "IlanVoice",
            path: "Sources/IlanVoice",
            // Swift 5 language mode: the code isn't written for Swift 6's strict concurrency checks yet.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
