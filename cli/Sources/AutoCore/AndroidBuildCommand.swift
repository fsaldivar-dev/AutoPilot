import Foundation

/// `auto-android build [module]` — wrapper sobre `gradle assembleDebug` para
/// la app Android configurada en `.autopilot`. Paridad con `auto build` iOS.
///
/// `.autopilot` fields leídos:
///   - `android_project`  path relativo al proyecto gradle (con gradlew)
///   - `android_module`   módulo a compilar (default: "app")
public enum AndroidBuildCommand {

    public static func execute(args: [String], start: CFAbsoluteTime) throws {
        let config = AutoPilotConfig.readAll()
        guard let projectPath = config["android_project"] else {
            print("Usage: set 'android_project' in .autopilot pointing to gradle project root")
            print("       auto-android config android_project Demo/Android/CameraTestApp")
            print("       auto-android config android_module app")
            print("       auto-android build")
            return
        }

        let rawModule = args.count >= 2 ? args[1] : (config["android_module"] ?? "app")
        // Validar: solo letras/números/guiones/underscores — evita que `:module:task` escape
        // a otros targets gradle via caracteres especiales.
        guard rawModule.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            print("Error: invalid module name '\(rawModule)' — use [A-Za-z0-9_-]")
            return
        }
        let moduleArg = rawModule
        let gradlew = "\(projectPath)/gradlew"

        guard FileManager.default.fileExists(atPath: gradlew) else {
            print("Error: gradlew not found at \(gradlew)")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: gradlew)
        proc.arguments = [":\(moduleArg):assembleDebug"]
        proc.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        print("→ gradle :\(moduleArg):assembleDebug")
        try proc.run()
        proc.waitUntilExit()

        if proc.terminationStatus == 0 {
            print("Build completed (\(elapsedMs(start))ms)")
        } else {
            print("Build failed (exit \(proc.terminationStatus))")
        }
    }
}
