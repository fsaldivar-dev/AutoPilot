// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "auto",
    platforms: [.macOS(.v13)],
    targets: [
        // Shared: protocol, models, script parser, config, tree printer
        .target(
            name: "AutoCore",
            path: "Sources/AutoCore"
        ),
        // iOS-specific: SimulatorBridge + AX helpers
        .target(
            name: "AutoLibiOS",
            dependencies: ["AutoCore"],
            path: "Sources/AutoLibiOS"
        ),
        // iOS CLI binary
        .executableTarget(
            name: "auto",
            dependencies: ["AutoCore", "AutoLibiOS"],
            path: "Sources/CLI"
        ),
        // Android CLI binary (stub)
        .executableTarget(
            name: "auto-android",
            dependencies: ["AutoCore"],
            path: "Sources/CLIAndroid"
        ),
        // iOS sidecar daemon — manages XCTest runner lifecycle via Unix socket
        .executableTarget(
            name: "autopilotd",
            dependencies: ["AutoCore"],
            path: "Sources/Daemon"
        ),
        .testTarget(
            name: "AutoTests",
            dependencies: ["AutoCore", "AutoLibiOS"],
            path: "Tests"
        )
    ]
)
