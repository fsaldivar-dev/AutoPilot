// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "auto",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AutoLib",
            path: "Sources/AutoLib"
        ),
        .executableTarget(
            name: "auto",
            dependencies: ["AutoLib"],
            path: "Sources/CLI"
        ),
        .testTarget(
            name: "AutoTests",
            dependencies: ["AutoLib"],
            path: "Tests"
        )
    ]
)
