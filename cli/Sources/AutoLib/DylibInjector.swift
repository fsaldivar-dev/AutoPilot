import Foundation

/// Compiles the camera mock ObjC code into a dylib and injects it into
/// a running (or about-to-launch) app via DYLD_INSERT_LIBRARIES.
/// No recompilation of the target app is needed.
public final class DylibInjector {

    private let fileManager = FileManager.default

    /// Persistent cache directory for the compiled dylib.
    private var cacheDir: String {
        let home = fileManager.homeDirectoryForCurrentUser.path
        return "\(home)/.autopilot"
    }

    /// Path to the cached dylib.
    private var dylibPath: String {
        "\(cacheDir)/libAutoPilotCapture.dylib"
    }

    public init() {}

    /// Returns the path to the dylib, compiling it if needed.
    public func ensureDylib() throws -> String {
        if fileManager.fileExists(atPath: dylibPath) {
            return dylibPath
        }
        return try compileDylib()
    }

    /// Forces a fresh recompilation of the dylib.
    @discardableResult
    public func recompile() throws -> String {
        try? fileManager.removeItem(atPath: dylibPath)
        return try compileDylib()
    }

    // MARK: - Private

    private func compileDylib() throws -> String {
        try fileManager.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        let sdkPath = try findSDKPath()
        let tempDir = NSTemporaryDirectory() + "autopilot-inject-\(ProcessInfo.processInfo.processIdentifier)"
        try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

        defer { try? fileManager.removeItem(atPath: tempDir) }

        // Write ObjC source
        let srcPath = "\(tempDir)/AutoPilotCapture.m"
        try MockHeaders.captureImplementation.write(
            toFile: srcPath,
            atomically: true,
            encoding: .utf8
        )

        print("[auto inject] Compiling camera mock dylib...")

        // Compile to dylib (shared library for iOS Simulator)
        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = [
            "clang",
            "-dynamiclib",
            "-arch", "arm64",
            "-isysroot", sdkPath,
            "-target", "arm64-apple-ios16.0-simulator",
            "-fobjc-arc",
            "-fno-modules",
            "-framework", "AVFoundation",
            "-framework", "UIKit",
            "-framework", "CoreMedia",
            "-framework", "QuartzCore",
            srcPath,
            "-o", dylibPath,
        ]

        let errPipe = Pipe()
        clang.standardError = errPipe
        try clang.run()
        clang.waitUntilExit()

        if clang.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw InjectError.compileFailed(errMsg)
        }

        let attrs = try fileManager.attributesOfItem(atPath: dylibPath)
        let size = attrs[.size] as? Int ?? 0
        print("[auto inject] Dylib cached: \(dylibPath) (\(size) bytes)")

        return dylibPath
    }

    private func findSDKPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphonesimulator", "--show-sdk-path"]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw InjectError.sdkNotFound
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

// MARK: - Errors

public enum InjectError: Error, CustomStringConvertible {
    case sdkNotFound
    case compileFailed(String)
    case imageNotFound(String)
    case noBundleId

    public var description: String {
        switch self {
        case .sdkNotFound:
            return "iOS Simulator SDK not found. Is Xcode installed?"
        case .compileFailed(let msg):
            return "Failed to compile camera mock dylib: \(msg)"
        case .imageNotFound(let path):
            return "Image not found: \(path)"
        case .noBundleId:
            return "No bundle ID provided. Usage: auto inject <bundleId> [image.jpg]"
        }
    }
}
