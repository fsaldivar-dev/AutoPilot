import Foundation
import AutoCore

/// Launch con integración a camera mock y parsing de flags (`--inject`, `--env`, `--recompile`).
/// iOS-específico porque depende de `SimulatorBridge.injectAndLaunch` y `DylibInjector`.
public enum iOSLaunchEnhancement {

    public static func execute(args: [String], simulatorBridge: SimulatorBridge, router: ActionRouter, start: CFAbsoluteTime) async throws {
        let config = AutoPilotConfig.readAll()
        let bundleId: String
        if args.count >= 2 && !args[1].hasPrefix("--") {
            bundleId = args[1]
        } else if let b = config["bundle"] {
            bundleId = b
        } else {
            printUsage()
            return
        }

        var envVars: [String: String] = [:]
        var injectImage: String? = nil
        var recompile = false

        if let img = config["image"] {
            envVars["AUTOPILOT_CAMERA_IMAGE"] = img
        }

        var i = args.count >= 2 && !args[1].hasPrefix("--") ? 2 : 1
        while i < args.count {
            if args[i] == "--env" && i + 1 < args.count {
                let pair = args[i + 1]
                if let eqIndex = pair.firstIndex(of: "=") {
                    let key = String(pair[pair.startIndex..<eqIndex])
                    let value = String(pair[pair.index(after: eqIndex)...])
                    envVars[key] = value
                }
                i += 2
            } else if args[i] == "--inject" {
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    injectImage = args[i + 1]
                    i += 2
                } else {
                    injectImage = config["image"]
                    i += 1
                }
            } else if args[i] == "--recompile" {
                recompile = true
                i += 1
            } else {
                i += 1
            }
        }

        if let injectImg = injectImage {
            var imgPath = injectImg
            if !imgPath.hasPrefix("/") {
                imgPath = FileManager.default.currentDirectoryPath + "/" + imgPath
            }

            if recompile {
                let injector = DylibInjector()
                try injector.recompile()
            }

            try simulatorBridge.injectAndLaunch(bundleId: bundleId, imagePath: imgPath, extraEnv: envVars)
            let ms = elapsedMs(start)
            print("Launched \(bundleId) with camera mock → \(imgPath) (\(ms)ms)")
        } else {
            // Launch vía router → SimCtlBackend (declara .launchApp).
            _ = try await router.execute(.launchApp(bundleId: bundleId, envVars: envVars))
            let ms = elapsedMs(start)
            if envVars.isEmpty {
                print("Launched \(bundleId) (\(ms)ms)")
            } else {
                print("Launched \(bundleId) with \(envVars.count) env var(s) (\(ms)ms)")
            }
        }
    }

    private static func printUsage() {
        print("Usage: auto launch <bundleId> [--inject image.jpg] [--env KEY=VALUE ...]")
        print("   or: auto config bundle com.example.app")
        print("       auto launch")
    }
}
