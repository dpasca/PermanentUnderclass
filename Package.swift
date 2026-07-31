// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "MeetingCopilot",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "MeetingCopilot", targets: ["MeetingCopilot"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio",
            exact: "0.15.4"
        )
    ],
    targets: [
        .executableTarget(
            name: "MeetingCopilot",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            linkerSettings: [
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "MeetingCopilotTests",
            dependencies: ["MeetingCopilot"]
        )
    ]
)
