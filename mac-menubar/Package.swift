// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "VoiceShot",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "VoiceShot", targets: ["VoiceShot"])
    ],
    targets: [
        .executableTarget(
            name: "VoiceShot",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Speech")
            ]
        )
    ]
)
