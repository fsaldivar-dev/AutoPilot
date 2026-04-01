// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AutoPilotAVFoundation",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "AutoPilotAVFoundation", targets: ["AutoPilotAVFoundation"])
    ],
    targets: [
        .target(
            name: "AutoPilotAVFoundation",
            path: "Sources/AutoPilotAVFoundation",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("UIKit")
            ]
        )
    ]
)
