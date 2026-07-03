import Foundation

/// Manages .autopilot config file in the current directory.
/// Stores key=value pairs for project settings.
public struct AutoPilotConfig {

    private static let filename = ".autopilot"

    private static var filePath: String {
        FileManager.default.currentDirectoryPath + "/\(filename)"
    }

    /// Read all config values.
    public static func readAll() -> [String: String] {
        guard let content = try? String(contentsOfFile: filePath, encoding: .utf8) else {
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

    /// Read a single config value.
    public static func get(_ key: String) -> String? {
        return readAll()[key]
    }

    /// Set a config value.
    public static func set(_ key: String, value: String) {
        var config = readAll()
        config[key] = value
        write(config)
    }

    /// Remove a config value.
    public static func remove(_ key: String) {
        var config = readAll()
        config.removeValue(forKey: key)
        write(config)
    }

    /// Write config to file.
    private static func write(_ config: [String: String]) {
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
        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
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
