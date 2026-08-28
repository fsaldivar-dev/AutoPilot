import Foundation

/// Wraps xcodebuild to inject a camera mock via force-loaded static library.
/// The static lib contains ObjC code that swizzles AVFoundation camera classes
/// at load time, replacing them with mock implementations that read images
/// from the AUTOPILOT_CAMERA_IMAGE environment variable.
public final class BuildInterceptor {

    private let fileManager = FileManager.default

    public init() {}

    /// Runs xcodebuild with camera mock injection.
    /// All arguments are forwarded to xcodebuild with `-force_load` added.
    public func build(args: [String]) throws {
        let sdkPath = try findSDKPath()
        let tempDir = try createTempDir()

        defer {
            try? fileManager.removeItem(atPath: tempDir)
        }

        print("[auto build] Preparing camera mock...")

        // 1. Write implementation to temp dir
        try MockHeaders.captureImplementation.write(
            toFile: "\(tempDir)/AutoPilotCapture.m",
            atomically: true,
            encoding: .utf8
        )

        // 2. Compile static library
        let libPath = "\(tempDir)/libAutoPilotCapture.a"
        try compileStaticLib(tempDir: tempDir, sdkPath: sdkPath, outputPath: libPath)

        print("[auto build] Mock compiled. Running xcodebuild...")

        // 3. Run xcodebuild with force_load
        try runXcodebuild(args: args, libPath: libPath)
    }

    // MARK: - Private

    private func findSDKPath() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["--sdk", "iphonesimulator", "--show-sdk-path"]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BuildError.sdkNotFound
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func createTempDir() throws -> String {
        let tempDir = NSTemporaryDirectory() + "autopilot-build-\(ProcessInfo.processInfo.processIdentifier)"
        try fileManager.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        return tempDir
    }

    private func compileStaticLib(tempDir: String, sdkPath: String, outputPath: String) throws {
        let objPath = "\(tempDir)/AutoPilotCapture.o"

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        clang.arguments = [
            "clang", "-c",
            "-arch", "arm64",
            "-isysroot", sdkPath,
            "-target", "arm64-apple-ios16.0-simulator",
            "-fobjc-arc",
            "-fno-modules",
            "\(tempDir)/AutoPilotCapture.m",
            "-o", objPath,
        ]

        let clangErr = Pipe()
        clang.standardError = clangErr
        try clang.run()
        clang.waitUntilExit()

        if clang.terminationStatus != 0 {
            let errData = clangErr.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw BuildError.compileFailed(errMsg)
        }

        // Create static library
        let ar = Process()
        ar.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        ar.arguments = ["ar", "rcs", outputPath, objPath]
        try ar.run()
        ar.waitUntilExit()

        guard ar.terminationStatus == 0 else {
            throw BuildError.compileFailed("ar failed")
        }

        let attrs = try fileManager.attributesOfItem(atPath: outputPath)
        let size = attrs[.size] as? Int ?? 0
        print("[auto build] Static lib: \(size) bytes")
    }

    private func runXcodebuild(args: [String], libPath: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var xcodebuildArgs = ["xcodebuild"] + args
        xcodebuildArgs += [
            // CoreImage: CIDetector decodifica el QR de la imagen inyectada para el
            // escaneo en vivo. CoreGraphics: los bounds del codigo usan
            // CGRectGetMaxX / CGPointCreateDictionaryRepresentation, y con
            // -fno-modules no hay autolink que los traiga.
            "OTHER_LDFLAGS=$(inherited) -force_load \(libPath) -framework AVFoundation -framework UIKit -framework CoreImage -framework CoreGraphics",
            "ENABLE_DEBUG_DYLIB=NO",
        ]

        process.arguments = xcodebuildArgs
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw BuildError.xcodebuildFailed(process.terminationStatus)
        }

        print("[auto build] Build succeeded with camera mock injected")
    }

    // MARK: - Observer lib build (ARD-002)

    /// Builds the app with libAutoPilotObserver.a linked via -force_load.
    /// Does NOT inject the camera mock — use build(args:) for that.
    public func buildWithObserver(args: [String]) throws {
        let libPath = try buildObserverLib()
        print("[auto build] Observer lib: \(libPath)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")

        var xcodebuildArgs = ["xcodebuild"] + args
        xcodebuildArgs += [
            "OTHER_LDFLAGS=$(inherited) -force_load \(libPath)",
            "ENABLE_DEBUG_DYLIB=NO",
        ]

        process.arguments = xcodebuildArgs
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw BuildError.xcodebuildFailed(process.terminationStatus)
        }
        print("[auto build] Build succeeded with AutoPilot observer injected")
    }

    private func buildObserverLib() throws -> String {
        let libDir = try findObserverLibDir()
        let outPath = "\(libDir)/build/libAutoPilotObserver.a"

        print("[auto build] Building libAutoPilotObserver.a...")
        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        make.arguments = ["-C", libDir]
        make.standardOutput = FileHandle.standardOutput
        make.standardError = FileHandle.standardError

        try make.run()
        make.waitUntilExit()

        guard make.terminationStatus == 0 else {
            throw BuildError.compileFailed("make failed in \(libDir)")
        }
        guard fileManager.fileExists(atPath: outPath) else {
            throw BuildError.compileFailed("libAutoPilotObserver.a not found after make at \(outPath)")
        }
        return outPath
    }

    private func findObserverLibDir() throws -> String {
        // Development: resolve relative to this source file → repo root / libs / AutoPilotObserver.
        // Installed binary: path relative to the CLI binary.
        let candidates: [String] = [
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()  // AutoLibiOS/
                .deletingLastPathComponent()  // Sources/
                .deletingLastPathComponent()  // cli/
                .deletingLastPathComponent()  // repo root
                .appendingPathComponent("libs/AutoPilotObserver")
                .path,
            URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent()
                .appendingPathComponent("../libs/AutoPilotObserver")
                .standardized.path,
        ]
        for candidate in candidates {
            if fileManager.fileExists(atPath: "\(candidate)/Makefile") { return candidate }
        }
        throw BuildError.compileFailed(
            "libs/AutoPilotObserver not found. Ensure the full repo is cloned."
        )
    }
}

// MARK: - Errors

public enum BuildError: Error, CustomStringConvertible {
    case sdkNotFound
    case compileFailed(String)
    case xcodebuildFailed(Int32)

    public var description: String {
        switch self {
        case .sdkNotFound:
            return "iOS Simulator SDK not found. Is Xcode installed?"
        case .compileFailed(let msg):
            return "Failed to compile camera mock: \(msg)"
        case .xcodebuildFailed(let code):
            return "xcodebuild failed with exit code \(code)"
        }
    }
}
