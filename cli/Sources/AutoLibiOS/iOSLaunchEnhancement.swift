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
        var withObserver = false

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
            } else if args[i] == "--observer" {
                withObserver = true
                i += 1
            } else {
                i += 1
            }
        }

        if recompile {
            try DylibInjector().recompile()
            if withObserver { try ObserverInjector().recompile() }
        }

        // 4 combinaciones: {camera?, observer?} → dispatch al helper correcto.
        let imgPath: String? = injectImage.map { img in
            img.hasPrefix("/") ? img : FileManager.default.currentDirectoryPath + "/" + img
        }

        switch (imgPath, withObserver) {
        case (.some(let path), true):
            try simulatorBridge.injectCameraAndObserverAndLaunch(
                bundleId: bundleId, imagePath: path, extraEnv: envVars)
            print("Launched \(bundleId) with camera + observer → \(path) (\(elapsedMs(start))ms)")
        case (.some(let path), false):
            try simulatorBridge.injectAndLaunch(
                bundleId: bundleId, imagePath: path, extraEnv: envVars)
            print("Launched \(bundleId) with camera mock → \(path) (\(elapsedMs(start))ms)")
        case (.none, true):
            try simulatorBridge.injectObserverAndLaunch(
                bundleId: bundleId, extraEnv: envVars)
            print("Launched \(bundleId) with observer (\(elapsedMs(start))ms)")
        case (.none, false):
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
        print("Usage: auto launch <bundleId> [--inject image.jpg] [--observer] [--env KEY=VALUE ...]")
        print("   or: auto config bundle com.example.app")
        print("       auto launch")
        print("")
        print("Flags:")
        print("  --inject [img]   Inyecta camera mock dylib al arrancar")
        print("  --observer       Inyecta libAutoPilotObserver.dylib (solo simulator)")
        print("                   → `tree`/`inspect` dejan de depender de Simulator.app foreground")
        print("  --env KEY=VALUE  Pasa env var al proceso del app")
        print("  --recompile      Fuerza recompilar dylib(s) antes de inyectar")
    }
}
