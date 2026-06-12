// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "LocalVoice",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LocalVoiceCore", targets: ["LocalVoiceCore"])
    ],
    targets: [
        .target(name: "LocalVoiceCore"),
        .testTarget(
            name: "LocalVoiceCoreTests",
            dependencies: ["LocalVoiceCore"]
        )
    ]
)
