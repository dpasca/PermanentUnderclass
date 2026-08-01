// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PUnderclass",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "punderclass", targets: ["MeetingCopilot"])
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
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("PDFKit"),
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
