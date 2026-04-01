// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "auto",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "auto",
            path: "Sources"
        )
    ]
)
