import Foundation

// UnknownCommand — error tipado + catálogo de comandos para el fallthrough
// del dispatcher (#152).
//
// **Problema que resuelve:** un comando no reconocido dentro de un script
// (`tapp "x"`) imprimía el help completo (~200 líneas) por cada línea
// inválida y el script terminaba "Script completed" con exit 0 — un falso
// positivo garantizado en CI.
//
// **Diseño:**
//   - `UnknownCommandError` viaja como error normal por la cadena
//     ScriptInterpreter → onUnknownCommand → executeCommand, así el script
//     falla con `FAIL at line N: Unknown command 'tapp'` + exit 1.
//   - El help completo solo se imprime en uso interactivo (invocación
//     directa `auto <cmd>` desde la terminal), nunca por línea de script.
//   - `CommandCatalog.suggest` calcula distancia Levenshtein (sin
//     dependencias, filosofía Swift-puro) contra el catálogo para sugerir
//     `¿quisiste decir 'tap'?` cuando la distancia es <= 2. La comparación
//     es case-insensitive: cubre el typo clásico `waitfor` → `waitFor`.

/// Comando no reconocido por ningún dispatcher (ni platform-specific ni
/// shared). `description` es el mensaje final visible para el usuario.
public struct UnknownCommandError: Error, CustomStringConvertible, Sendable {
    public let command: String
    public let suggestion: String?

    public init(command: String, suggestion: String?) {
        self.command = command
        self.suggestion = suggestion
    }

    public var description: String {
        if let suggestion {
            return "Unknown command '\(command)' (¿quisiste decir '\(suggestion)'?)"
        }
        return "Unknown command '\(command)'"
    }
}

/// Catálogo de comandos conocidos para sugerencias de typos.
public enum CommandCatalog {

    /// Comandos del dispatcher compartido (CommandDispatcher.swift).
    /// Los CLIs agregan sus comandos platform-specific vía `extra:`.
    public static let shared: [String] = [
        "tree", "layout", "tap", "longPress", "doubleTap", "clear", "type",
        "scroll", "swipe", "screenshot", "assertScreen", "exists", "visible",
        "isVisible", "hasText", "assertOCR", "platform", "orientation",
        "terminate", "elementAt", "tapAt", "media", "paste", "boot",
        "shutdown", "install", "list", "openurl", "waitFor", "waitUntilGone",
        "config", "wait", "sleep", "drag", "biometric", "faceid",
        "permission", "logs", "rotate", "pressKey", "hideKeyboard",
        "eraseText", "copyTextFrom", "clearState", "uninstall", "keychain",
        "accounts", "scrollTo", "scrollUntilVisible", "startRecording",
        "stopRecording", "setLocation", "setAppearance", "lockDevice",
        "unlockDevice", "pushFile", "pullFile",
    ]

    /// Sugerencia por distancia de edición contra `shared` + `extra`.
    /// Devuelve el comando más cercano si la distancia (case-insensitive)
    /// es <= 2; nil si el typo está demasiado lejos de todo el catálogo.
    public static func suggest(_ command: String, extra: [String] = []) -> String? {
        let needle = command.lowercased()
        guard !needle.isEmpty else { return nil }

        var best: (candidate: String, distance: Int)?
        for candidate in shared + extra {
            let d = levenshtein(needle, candidate.lowercased())
            if d <= 2 && (best == nil || d < best!.distance) {
                best = (candidate, d)
                if d == 0 { break } // no puede mejorar (typo de mayúsculas)
            }
        }
        return best?.candidate
    }

    /// Construye el error listo para lanzar desde el fallthrough del CLI.
    public static func unknownCommandError(_ command: String, extra: [String] = []) -> UnknownCommandError {
        UnknownCommandError(command: command, suggestion: suggest(command, extra: extra))
    }

    /// Distancia Levenshtein clásica (DP con dos filas). Suficiente para
    /// nombres de comandos (< 20 chars) — no necesita optimización mayor.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        if a == b { return 0 }
        let aChars = Array(a), bChars = Array(b)
        if aChars.isEmpty { return bChars.count }
        if bChars.isEmpty { return aChars.count }

        var previous = Array(0...bChars.count)
        var current = [Int](repeating: 0, count: bChars.count + 1)

        for i in 1...aChars.count {
            current[0] = i
            for j in 1...bChars.count {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[bChars.count]
    }
}
