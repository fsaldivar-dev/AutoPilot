import Foundation

/// #197: cada `xcrun simctl ...` re-resuelve el developer dir (xcode-select)
/// antes de localizar simctl — ~30-80ms por invocación, y el hot path hace
/// decenas (screenshot, clearState, biometric, launch, apps…). Resolver
/// `xcode-select -p` UNA vez y exportarlo como DEVELOPER_DIR hace que todos
/// los xcrun hijos lo hereden y salten esa resolución (~5ms).
///
/// Llamar una vez al arrancar el binario. Idempotente y no-op si el usuario
/// ya tiene DEVELOPER_DIR en su entorno.
public enum DeveloperDir {
    public static func ensureExported() {
        if let existing = ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
           !existing.isEmpty {
            return
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return }
        setenv("DEVELOPER_DIR", path, 1)
    }
}
