import Foundation
import AutoCore

/// Sub-comando `auto runner <install|status>`. Gestiona el runner XCTest que el daemon mantiene vivo.
public enum iOSRunnerCommand {

    public static func execute(_ args: [String], bridge: any DeviceBridge) throws {
        guard let sub = args.first, ["install", "status"].contains(sub) else {
            print("Usage: auto runner <install|status>")
            return
        }

        let installer = RunnerInstaller()

        switch sub {
        case "install":
            guard args.count >= 2 else {
                print("Usage: auto runner install <path/to/Runner.app> [--udid <UDID>]")
                return
            }
            let bundlePath = args[1]
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: bundlePath, isDirectory: &isDir), isDir.boolValue else {
                print("error: \(bundlePath) does not exist or is not a directory")
                return
            }

            let udid: String
            if let udidIdx = args.firstIndex(of: "--udid"), udidIdx + 1 < args.count {
                let raw = args[udidIdx + 1]
                guard raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), raw.count <= 40 else {
                    print("error: invalid UDID format")
                    return
                }
                udid = raw
            } else {
                udid = try bridge.getBootedDeviceId()
            }
            let result = try installer.installIfNeeded(sourceBundlePath: bundlePath, udid: udid)
            print("installed: \(result.appPath)")
            print("xctestrun: \(result.xctestRunPath)")
            print("version: \(result.version.prefix(8))")

        case "status":
            let baseDir = RunnerInstaller.runnerBaseDir
            let hashFile = RunnerInstaller.hashFile
            if let hash = try? String(contentsOfFile: hashFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
                print("runner: installed (hash=\(hash.prefix(8)))")
                print("path: \(baseDir)")
            } else {
                print("runner: not installed")
                print("hint: auto runner install <path/to/Runner.app>")
            }

        default:
            break
        }
    }
}
