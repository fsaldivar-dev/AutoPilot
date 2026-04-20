import Foundation

/// Prepara `libAutoPilotObserver.dylib` para inyección en un app del simulator
/// vía `SIMCTL_CHILD_DYLD_INSERT_LIBRARIES`. Mismo patrón que `DylibInjector`
/// (camera mock) pero delega la compilación al Makefile del Observer para
/// reusar exactamente el mismo build que produce el `.a` static para device.
///
/// Device físico NO soporta este método — iOS sandbox bloquea DYLD injection.
/// Para device usar `auto build` (static lib linkeada con `-force_load`).
public final class ObserverInjector {

    private let fileManager = FileManager.default

    /// Cache persistente para el .dylib compilado.
    public static var cachedDylibPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.autopilot/libAutoPilotObserver.dylib"
    }

    public init() {}

    /// Retorna el path al .dylib, compilándolo si no existe.
    public func ensureDylib() throws -> String {
        let path = Self.cachedDylibPath
        if fileManager.fileExists(atPath: path) {
            return path
        }
        return try compile()
    }

    /// Fuerza recompilación.
    @discardableResult
    public func recompile() throws -> String {
        try? fileManager.removeItem(atPath: Self.cachedDylibPath)
        return try compile()
    }

    // MARK: - Private

    private func compile() throws -> String {
        let cacheDir = (Self.cachedDylibPath as NSString).deletingLastPathComponent
        try fileManager.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        guard let libDir = findObserverLibDir() else {
            throw InjectError.compileFailed("libs/AutoPilotObserver not found (looked upward from CWD)")
        }

        print("[auto observer] Building libAutoPilotObserver.dylib...")

        let make = Process()
        make.executableURL = URL(fileURLWithPath: "/usr/bin/make")
        make.arguments = ["dylib"]
        make.currentDirectoryURL = URL(fileURLWithPath: libDir)

        let errPipe = Pipe()
        make.standardError = errPipe
        make.standardOutput = Pipe()
        try make.run()
        make.waitUntilExit()

        guard make.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "unknown"
            throw InjectError.compileFailed("make dylib failed: \(errMsg)")
        }

        let built = "\(libDir)/build/libAutoPilotObserver.dylib"
        guard fileManager.fileExists(atPath: built) else {
            throw InjectError.compileFailed("libAutoPilotObserver.dylib not found after make at \(built)")
        }

        // Copiar a cache (~/.autopilot/) — mismo patrón que camera dylib.
        try? fileManager.removeItem(atPath: Self.cachedDylibPath)
        try fileManager.copyItem(atPath: built, toPath: Self.cachedDylibPath)

        let attrs = try fileManager.attributesOfItem(atPath: Self.cachedDylibPath)
        let size = attrs[.size] as? Int ?? 0
        print("[auto observer] Dylib cached: \(Self.cachedDylibPath) (\(size) bytes)")

        return Self.cachedDylibPath
    }

    /// Busca `libs/AutoPilotObserver/` subiendo desde el CWD y desde el path
    /// del binario `auto` — así funciona tanto cuando el user está parado en
    /// el repo (CWD match) como cuando ejecuta `auto` desde cualquier lado
    /// (match por ubicación del binario: `cli/.build/*/auto` → sube 3 niveles
    /// → repo root).
    private func findObserverLibDir() -> String? {
        let searchStarts: [String] = [
            fileManager.currentDirectoryPath,
            (CommandLine.arguments.first.flatMap {
                Self.absolutePath(forExecutable: $0)
            } ?? "") as String,
        ].filter { !$0.isEmpty }

        for start in searchStarts {
            var dir = start
            for _ in 0..<8 {
                let candidate = "\(dir)/libs/AutoPilotObserver"
                if fileManager.fileExists(atPath: "\(candidate)/Makefile") {
                    return candidate
                }
                let parent = (dir as NSString).deletingLastPathComponent
                if parent == dir { break }
                dir = parent
            }
        }
        return nil
    }

    private static func absolutePath(forExecutable path: String) -> String? {
        if path.hasPrefix("/") { return (path as NSString).deletingLastPathComponent }
        let cwd = FileManager.default.currentDirectoryPath
        let full = "\(cwd)/\(path)"
        if FileManager.default.fileExists(atPath: full) {
            return (full as NSString).deletingLastPathComponent
        }
        return nil
    }
}
