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
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", branch: "main")
    ],
    targets: [
        .executableTarget(
            name: "VoiceShot",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("Speech")
            ]
        )
    ]
)
