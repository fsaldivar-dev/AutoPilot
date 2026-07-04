import Foundation

// `auto-android apps` (#187) — lista los paquetes instalados del emulador.
// Output parseable (fuente del predictivo de bundleId del editor): una línea
// por app `packageId<TAB>packageId` (pm no expone display names sin aapt —
// se repite el id para mantener el mismo shape que iOS). Por default solo
// apps de usuario (-3); `--all` incluye las de sistema.
public enum AndroidAppsCommand {
    public static func execute(args: [String], deviceId: String?) throws {
        let includeSystem = args.contains("--all")
        let adb = try AdbLegacyBridge(deviceId: deviceId).adbPathPublic()

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: adb)
        var arguments: [String] = []
        if let deviceId { arguments += ["-s", deviceId] }
        arguments += ["shell", "pm", "list", "packages"]
        if !includeSystem { arguments.append("-3") }
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let out = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        guard process.terminationStatus == 0 else {
            throw BridgeError.adbFailed("pm list packages")
        }

        let packages = out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("package:") }
            .map { String($0.dropFirst("package:".count)) }
            .sorted()

        for pkg in packages {
            print("\(pkg)\t\(pkg)")
        }
        if packages.isEmpty {
            print("(sin apps de usuario — usa `apps --all` para incluir las de sistema)")
        }
    }
}
