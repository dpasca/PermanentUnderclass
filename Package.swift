// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "PUnderclass",
    platforms: [
        .macOS("14.2")
    ],
    products: [
        .executable(name: "punderclass", targets: ["PUnderclass"])
    ],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio",
            exact: "0.15.4"
        ),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift",
            exact: "1.0.0"
        ),
        .package(
            url: "https://github.com/hummingbird-project/hummingbird.git",
            exact: "2.22.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "PUnderclass",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AVFAudio"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Security"),
                .linkedFramework("SwiftUI")
            ]
        ),
        .testTarget(
            name: "PUnderclassTests",
            dependencies: [
                "PUnderclass",
                .product(name: "HummingbirdTesting", package: "hummingbird")
            ]
        )
    ]
)
