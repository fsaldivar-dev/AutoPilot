import Foundation
import CommonCrypto
import AutoCore

// MARK: - RunnerInstaller
//
// Manages the XCTest runner bundle installation on iOS simulators.
// - Copies precompiled runner to ~/.autopilot/runner/
// - Installs via simctl install (idempotent, hash-based skip)
// - Regenerates .xctestrun plist with correct absolute paths

public final class RunnerInstaller {
    public static let runnerBaseDir = "\(NSHomeDirectory())/.autopilot/runner"
    public static let hashFile = "\(runnerBaseDir)/.hash"
    public static let runnerBundleID = "dev.autopilot.runner.xctrunner"

    public struct InstalledRunner {
        public let appPath: String        // Runner.app
        public let xctestPath: String     // Runner.app/PlugIns/AutoPilotRunnerUITests.xctest
        public let xctestRunPath: String  // .xctestrun file
        public let version: String        // hash of the bundle
    }

    public init() {}

    // MARK: - Install

    /// Install runner from `sourceBundlePath` to ~/.autopilot/runner/ and into the simulator.
    /// Skips if hash matches (already installed). Returns resolved paths.
    public func installIfNeeded(sourceBundlePath: String, udid: String) throws -> InstalledRunner {
        let fm = FileManager.default

        // Ensure base dir exists
        try fm.createDirectory(atPath: Self.runnerBaseDir, withIntermediateDirectories: true)

        // Compute hash of source bundle
        let sourceHash = try hashOfDirectory(sourceBundlePath)
        let existingHash = try? String(contentsOfFile: Self.hashFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let bundleName = URL(fileURLWithPath: sourceBundlePath).lastPathComponent
        let destAppPath = "\(Self.runnerBaseDir)/\(bundleName)"

        if sourceHash == existingHash && fm.fileExists(atPath: destAppPath) {
            fputs("runner up to date (hash=\(sourceHash.prefix(8)))\n", stderr)
        } else {
            // Copy bundle
            if fm.fileExists(atPath: destAppPath) {
                try fm.removeItem(atPath: destAppPath)
            }
            try fm.copyItem(atPath: sourceBundlePath, toPath: destAppPath)

            // Write hash (before install — copy is the expensive part)
            try sourceHash.write(toFile: Self.hashFile, atomically: true, encoding: .utf8)

            // Install into simulator
            try simctlInstall(udid: udid, appPath: destAppPath)

            fputs("runner installed (hash=\(sourceHash.prefix(8)))\n", stderr)
        }

        // Resolve paths
        let xctestPath = findXCTest(in: destAppPath)
        let xctestRunPath = try regenerateXCTestRun(
            appPath: destAppPath,
            xctestPath: xctestPath,
            udid: udid
        )

        return InstalledRunner(
            appPath: destAppPath,
            xctestPath: xctestPath ?? destAppPath,
            xctestRunPath: xctestRunPath,
            version: sourceHash
        )
    }

    // MARK: - xctestrun regeneration

    /// Generates a .xctestrun plist with absolute paths pointing to the installed runner.
    /// Uses PropertyListSerialization for safe plist manipulation.
    /// The bundle name is auto-detected from the actual .xctest inside Runner.app/PlugIns/.
    public func regenerateXCTestRun(appPath: String, xctestPath: String?, udid: String) throws -> String {
        let xctestRunPath = "\(Self.runnerBaseDir)/AutoPilotRunner.xctestrun"

        // Discover Xcode platform path
        let platformPath = try discoverPlatformPath()

        // Resolve test bundle path — use provided or auto-detect from PlugIns/
        guard let resolvedXctestPath = xctestPath else {
            throw BridgeError.simctlFailed("no .xctest bundle found in \(appPath)/PlugIns/")
        }
        let testBundleName = URL(fileURLWithPath: resolvedXctestPath).lastPathComponent
        // Bundle key: "Foo.xctest" → "Foo"
        let bundleKey = (testBundleName as NSString).deletingPathExtension

        // Estructura .xctestrun FORMATO 2.
        //
        // El bug que arregla esto (#355): antes se declaraba FormatVersion 2 pero se
        // escribia la FORMA de v1 —los targets colgando de la raiz—. Xcode 26 lee la
        // version, busca TestConfigurations y no lo encuentra:
        //   Dictionary does not contain key "TestConfigurations"
        // En v2 los targets viven dentro de TestConfigurations[].TestTargets[].
        //
        // Las rutas van con __TESTROOT__ (el directorio que contiene este .xctestrun)
        // en vez de absolutas. Esa es la diferencia entre un archivo que solo sirve en
        // la maquina que lo genero y uno distribuible: el workaround anterior apuntaba
        // al DerivedData de Xcode, cuyo hash de proyecto no existe en otra maquina.
        let appName = URL(fileURLWithPath: appPath).lastPathComponent
        let testRoot = "__TESTROOT__/\(appName)"

        // El modulo Swift no admite espacios ni guiones; Xcode aplica la misma regla.
        let moduleName = bundleKey
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")

        let testTarget: [String: Any] = [
            "BlueprintName": bundleKey,
            "BlueprintProviderName": "AutoPilotRunner",
            "ProductModuleName": moduleName,

            "TestBundlePath": "__TESTHOST__/PlugIns/\(testBundleName)",
            "TestHostPath": testRoot,
            "TestHostBundleIdentifier": try bundleIdentifier(ofApp: appPath),
            "DependentProductPaths": [testRoot],

            // UITargetAppPath apunta al PROPIO runner, y esto se midio: omitirlo
            // parecia correcto —el runner se adjunta en tiempo de ejecucion con
            // XCUIApplication(bundleIdentifier:), no a una app fija— pero xcodebuild
            // lo rechaza de plano:
            //   Cannot test target ...: UITargetAppPath should be provided
            // Es un requisito estatico, no funcional. Apuntarlo al runner lo satisface
            // sin introducir una dependencia externa: el bundle siempre esta ahi, al
            // lado del .xctestrun. Solo afectaria al fallback XCUIApplication() sin
            // bundleId, que el daemon no usa.
            "UITargetAppPath": testRoot,
            "IsUITestBundle": true,
            "IsXCTRunnerHostedTestBundle": true,

            "TestingEnvironmentVariables": [
                "DYLD_INSERT_LIBRARIES": "\(platformPath)/Developer/usr/lib/libXCTestBundleInject.dylib",
                "DYLD_LIBRARY_PATH": "\(platformPath)/Developer/usr/lib",
                "DYLD_FRAMEWORK_PATH": "\(platformPath)/Developer/Library/Frameworks:\(platformPath)/Developer/Library/PrivateFrameworks",
                "XCTestConfigurationFilePath": "__TESTHOST__/\(testBundleName)",
            ] as [String: String],
            "EnvironmentVariables": [String: String](),
            "CommandLineArguments": [String](),

            "SkipTestIdentifiers": [String](),
            "OnlyTestIdentifiers": ["AutoPilotRunnerTests/testServe"],

            // El runner sirve peticiones indefinidamente: sin esto XCTest lo mata a
            // los 600s por defecto y el daemon pierde la conexion a media sesion.
            "TestTimeoutsEnabled": false,
            "TestLanguage": "",
            "TestRegion": "",
        ]

        let testConfig: [String: Any] = [
            "__xctestrun_metadata__": [
                "FormatVersion": 2,
            ] as [String: Any],
            "ContainerInfo": [
                "ContainerName": "AutoPilotRunner",
                "SchemeName": "AutoPilotRunner",
            ] as [String: String],
            "TestPlan": [
                "Name": "AutoPilotRunner",
                "IsDefault": true,
            ] as [String: Any],
            "TestConfigurations": [
                [
                    "Name": "AutoPilot",
                    "IsEnabled": true,
                    "TestTargets": [testTarget],
                ] as [String: Any]
            ],
        ]

        let data = try PropertyListSerialization.data(
            fromPropertyList: testConfig,
            format: .xml,
            options: 0
        )
        try data.write(to: URL(fileURLWithPath: xctestRunPath))

        return xctestRunPath
    }

    // MARK: - Helpers

    /// Lee el CFBundleIdentifier del Runner.app en vez de asumirlo.
    ///
    /// Estaba hardcodeado a `runnerBundleID` y no coincidia con el bundle real
    /// (`dev.autopilot.test.ExploreaUITests.xctrunner`): el id lo fija el proyecto
    /// Xcode que compila el runner, asi que cualquiera que lo genere desde otro
    /// proyecto tendria uno distinto. Para un runner distribuible no se puede
    /// suponer.
    private func bundleIdentifier(ofApp appPath: String) throws -> String {
        let plistPath = "\(appPath)/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = try PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any],
              let identifier = plist["CFBundleIdentifier"] as? String,
              !identifier.isEmpty
        else {
            throw BridgeError.simctlFailed(
                "no se pudo leer CFBundleIdentifier de \(plistPath)")
        }
        return identifier
    }

    private func simctlInstall(udid: String, appPath: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["simctl", "install", udid, appPath]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw BridgeError.simctlFailed("simctl install failed: \(errMsg)")
        }
    }

    private func discoverPlatformPath() throws -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["--sdk", "iphonesimulator", "--show-sdk-platform-path"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()

        guard proc.terminationStatus == 0 else {
            throw BridgeError.simctlFailed("xcrun --show-sdk-platform-path failed")
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !path.isEmpty else {
            throw BridgeError.simctlFailed("empty platform path from xcrun")
        }
        return path
    }

    private func findXCTest(in appPath: String) -> String? {
        let pluginsDir = "\(appPath)/PlugIns"
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: pluginsDir) else { return nil }
        if let xctest = contents.first(where: { $0.hasSuffix(".xctest") }) {
            return "\(pluginsDir)/\(xctest)"
        }
        return nil
    }

    /// Compute a simple hash of a directory by hashing the sorted file listing + sizes.
    /// Not cryptographically rigorous — just enough to detect bundle changes.
    private func hashOfDirectory(_ path: String) throws -> String {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else {
            throw BridgeError.simctlFailed("cannot enumerate \(path)")
        }

        var entries: [String] = []
        while let relativePath = enumerator.nextObject() as? String {
            let fullPath = "\(path)/\(relativePath)"
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue {
                let attrs = try fm.attributesOfItem(atPath: fullPath)
                let size = (attrs[.size] as? UInt64) ?? 0
                entries.append("\(relativePath):\(size)")
            }
        }

        entries.sort()
        let manifest = entries.joined(separator: "\n")
        guard let data = manifest.data(using: .utf8) else {
            throw BridgeError.simctlFailed("cannot encode manifest")
        }

        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { ptr in
            _ = CC_SHA256(ptr.baseAddress, CC_LONG(data.count), &digest)
        }

        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
