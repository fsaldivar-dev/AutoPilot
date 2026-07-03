import Foundation

/// Maneja el archivo de config `.autopilot` (pares key=value).
///
/// Resolución en cascada (issue #131) — antes todo era relativo al cwd,
/// lo que rompía comandos fuera de la raíz del repo y escribía
/// `./.autopilot` silenciosamente en cualquier directorio:
///   1. Si existe `./.autopilot` en el cwd, se usa (comportamiento clásico).
///   2. Si no, se camina hacia arriba buscando `.autopilot`, acotado por la
///      raíz del repo (`RepoRoot.find`) para no leer configs ajenos.
///   3. Al escribir sin config existente, se crea en el cwd imprimiendo la
///      ruta absoluta, para que el efecto nunca sea silencioso.
///
/// Además, las claves que son rutas (`project`, `image`, `android_project`)
/// se resuelven relativas al directorio del `.autopilot` al leerlas, para
/// que `auto build` funcione igual desde cualquier subdirectorio. El archivo
/// en disco conserva las rutas relativas (portables entre máquinas).
public struct AutoPilotConfig {

    private static let filename = ".autopilot"

    /// Claves cuyo valor es una ruta relativa al directorio del config.
    private static let pathKeys: Set<String> = ["project", "image", "android_project"]

    /// Ruta del `.autopilot` existente más cercano, o nil si no hay ninguno.
    /// Camina desde `start` hacia arriba sin pasar de la raíz del repo
    /// (si no hay repo, solo se considera el propio `start`).
    static func resolvedFilePath(startingAt start: String = FileManager.default.currentDirectoryPath) -> String? {
        let repoRoot = RepoRoot.find(startingAt: start)
        var dir = start
        while true {
            let candidate = "\(dir)/\(filename)"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
            if dir == repoRoot || dir == "/" { return nil }
            dir = (dir as NSString).deletingLastPathComponent
        }
    }

    /// Read all config values (rutas resueltas contra el dir del config).
    public static func readAll() -> [String: String] {
        readAll(startingAt: FileManager.default.currentDirectoryPath)
    }

    static func readAll(startingAt start: String) -> [String: String] {
        guard let path = resolvedFilePath(startingAt: start) else { return [:] }
        var config = readRaw(at: path)

        // Resolver rutas relativas contra el directorio del config, no el cwd.
        let configDir = (path as NSString).deletingLastPathComponent
        for key in pathKeys {
            if let value = config[key], !value.hasPrefix("/"), !value.hasPrefix("~") {
                config[key] = configDir + "/" + value
            }
        }
        return config
    }

    /// Read a single config value.
    public static func get(_ key: String) -> String? {
        return readAll()[key]
    }

    /// Set a config value.
    public static func set(_ key: String, value: String) {
        set(key, value: value, startingAt: FileManager.default.currentDirectoryPath)
    }

    static func set(_ key: String, value: String, startingAt start: String) {
        let target: String
        var config: [String: String]
        var created = false
        if let existing = resolvedFilePath(startingAt: start) {
            target = existing
            config = readRaw(at: existing)
        } else {
            target = "\(start)/\(filename)"
            config = [:]
            created = true
        }
        config[key] = value
        write(config, to: target)
        if created {
            print("→ config guardado en \(target)")
        }
    }

    /// Remove a config value.
    public static func remove(_ key: String) {
        remove(key, startingAt: FileManager.default.currentDirectoryPath)
    }

    static func remove(_ key: String, startingAt start: String) {
        guard let path = resolvedFilePath(startingAt: start) else { return }
        var config = readRaw(at: path)
        config.removeValue(forKey: key)
        write(config, to: path)
    }

    /// Lee el archivo tal cual, sin resolver rutas — es lo que se usa para
    /// reescribirlo, de modo que las rutas relativas queden intactas en disco.
    private static func readRaw(at path: String) -> [String: String] {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return [:]
        }
        var config: [String: String] = [:]
        for line in content.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if let eq = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                config[key] = value
            }
        }
        return config
    }

    /// Write config to file.
    private static func write(_ config: [String: String], to path: String) {
        let order = ["project", "scheme", "device", "bundle", "image"]
        var lines: [String] = []

        // Write known keys in order
        for key in order {
            if let val = config[key] {
                lines.append("\(key)=\(val)")
            }
        }
        // Write remaining keys
        for (key, val) in config.sorted(by: { $0.key < $1.key }) {
            if !order.contains(key) {
                lines.append("\(key)=\(val)")
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// Valid config keys with descriptions.
    public static let knownKeys: [(key: String, description: String)] = [
        ("project", "Ruta al .xcodeproj (iOS)"),
        ("scheme", "Scheme de Xcode (iOS)"),
        ("device", "Nombre o UDID del simulador (iOS)"),
        ("bundle", "Bundle ID / package de la app"),
        ("image", "Ruta a imagen para camara mock"),
        ("android_project", "Raiz del proyecto gradle, requerido por build (Android)"),
        ("android_module", "Modulo gradle a compilar, default: app (Android)"),
    ]
}
