import Foundation
import Darwin

/// Sub-comando `auto daemon <start|stop|status>`. Lanza o consulta el sidecar `autopilotd`.
public enum iOSDaemonCommand {

    public static func execute(_ args: [String]) throws {
        guard let sub = args.first, ["start", "stop", "status"].contains(sub) else {
            print("Usage: auto daemon <start|stop|status> [--udid <UDID>] [--timeout <seconds>]")
            return
        }

        // Resolver el path real del binario `auto` — `CommandLine.arguments[0]`
        // es solo el nombre cuando se invoca desde PATH, lo que hacía que el
        // daemon se buscara en el cwd del usuario.
        let autoPath = resolveExecutablePath()
        let autoDir = URL(fileURLWithPath: autoPath).deletingLastPathComponent().path
        let daemonPath = "\(autoDir)/autopilotd"

        guard FileManager.default.fileExists(atPath: daemonPath) else {
            print("error: autopilotd not found at \(daemonPath)")
            print("hint: run 'swift build' to compile the daemon")
            exit(1)
        }

        // Validate and filter arguments: only allow known flags with safe values
        var sanitizedArgs: [String] = [sub]
        let remaining = Array(args.dropFirst())
        var i = 0
        while i < remaining.count {
            let arg = remaining[i]
            if arg == "--udid", i + 1 < remaining.count {
                let udid = remaining[i + 1]
                let safe = udid.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
                guard safe, udid.count <= 40 else {
                    print("error: invalid UDID format")
                    return
                }
                sanitizedArgs += ["--udid", udid]
                i += 2
            } else if arg == "--timeout", i + 1 < remaining.count {
                guard Double(remaining[i + 1]) != nil else {
                    print("error: --timeout must be a number")
                    return
                }
                sanitizedArgs += ["--timeout", remaining[i + 1]]
                i += 2
            } else {
                i += 1
            }
        }

        switch sub {
        case "start":
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: daemonPath)
            proc.arguments = sanitizedArgs
            proc.standardOutput = FileHandle.standardOutput
            proc.standardError = FileHandle.standardError
            try proc.run()
            print("daemon launched (pid=\(proc.processIdentifier))")

        case "stop", "status":
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: daemonPath)
            proc.arguments = sanitizedArgs
            proc.standardOutput = FileHandle.standardOutput
            proc.standardError = FileHandle.standardError
            try proc.run()
            proc.waitUntilExit()

        default:
            break
        }
    }

    /// Resuelve la ruta real del binario ejecutándose (sigue symlinks).
    /// Necesario cuando `auto` se invoca desde PATH y `arguments[0]` es
    /// solo el nombre sin directorio.
    private static func resolveExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else {
            return CommandLine.arguments[0]
        }
        let raw = String(cString: buf)
        return (raw as NSString).resolvingSymlinksInPath
    }
}
