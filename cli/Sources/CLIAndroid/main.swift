import Foundation
import AutoCore

// #162: los tips accionables de BridgeError usan el nombre del binario —
// aquí corre `auto-android`, no `auto`.
BridgeError.binaryName = "auto-android"

let useLegacy = CommandLine.arguments.contains("--legacy")

// Bootstrap de plataforma vía AndroidDeviceResolver (ARD-001).
// --legacy cambia qué backend se registra (AdbBackend en lugar de AgentBackend).
let deviceResolver = AndroidDeviceResolver(useLegacy: useLegacy)
let router = deviceResolver.router
let bridge: any DeviceBridge = deviceResolver.legacyBridge

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst().filter { $0 != "--legacy" })

    guard let cmd = args.first else {
        AndroidUsage.printUsage()
        return
    }

    if cmd == "run" {
        guard args.count >= 2 else {
            print("Usage: auto-android run <script.auto>")
            return
        }
        try runScript(path: args[1])
        return
    }

    if cmd == "interactive" {
        runInteractive()
        return
    }

    // Uso interactivo (invocación directa desde la terminal): un comando
    // desconocido SÍ imprime el help completo — pero con exit 1 (#152).
    do {
        try executeCommand(args)
    } catch let err as UnknownCommandError {
        print(err.description)
        print()
        AndroidUsage.printUsage()
        exit(1)
    }
}

/// Comandos que resuelve este main (no están en el shared dispatcher).
/// Alimenta la sugerencia Levenshtein del fallthrough (#152).
let androidCommandCatalogExtras: [String] = [
    "ping", "index", "inspect", "launch", "camera", "inject", "build",
    "record", "agent", "setup", "doctor", "help", "run", "interactive",
    "apps",
]

func runScript(path: String) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)

    let totalStart = CFAbsoluteTimeGetCurrent()

    // Parse estructural (soporta if/repeat/try/assert); backward-compat total
    // para scripts sin control flow.
    let statements: [ScriptStatement]
    do {
        statements = try parseStatements(content)
    } catch {
        print("Parse error: \(error)")
        exit(1)
    }

    // Interpreter + delegación al dispatcher legacy para todos los comandos
    // (preserva logs, semántica y comandos no mapeados como camera/doctor/etc.).
    let interp = ScriptInterpreter(router: router) { tokens, line in
        do {
            try executeCommand(tokens)
        } catch {
            print("FAIL at line \(line): \(error)")
            throw error
        }
    }

    // Bridge sync → async. nonisolated(unsafe) evita el error de strict
    // concurrency; la sincronización real la garantiza el DispatchSemaphore
    // (main thread espera hasta que el Task termine y signalee).
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var runError: Error?
    Task {
        defer { sem.signal() }
        do {
            try await interp.run(statements)
        } catch {
            runError = error
        }
    }
    sem.wait()

    if let err = runError {
        print("Script failed: \(err)")
        exit(1)
    }

    let totalMs = elapsedMs(totalStart)
    print("\nScript completed (\(totalMs)ms)")
}

/// REPL for Android. Keeps the bridge alive between commands.
func runInteractive() {
    setvbuf(stdout, nil, _IOLBF, 0)

    print(InteractiveJSON.ready(platform: "android"))
    fflush(stdout)

    while let rawLine = readLine(strippingNewline: true) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            print(InteractiveJSON.skipped())
            fflush(stdout)
            continue
        }

        if trimmed == "exit" || trimmed == "quit" {
            print(InteractiveJSON.bye())
            fflush(stdout)
            break
        }

        let start = CFAbsoluteTimeGetCurrent()
        let tokens = tokenize(trimmed)
        if tokens.isEmpty {
            print(InteractiveJSON.skipped())
            fflush(stdout)
            continue
        }

        let result = captureStdoutThrowing {
            try executeCommand(tokens)
        }

        let ms = elapsedMs(start)
        let out = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if let err = result.error {
            let message = "\(err)"
            print(InteractiveJSON.error(ms: ms, message: message, out: out))
        } else {
            print(InteractiveJSON.ok(ms: ms, out: out))
        }
        fflush(stdout)
    }
}

func executeCommand(_ args: [String]) throws {
    guard let rawCmd = args.first else { return }

    // Strip [role] suffix for switch matching: "tap[button]" → "tap"
    let cmd: String
    if let bracket = rawCmd.firstIndex(of: "[") {
        cmd = String(rawCmd[rawCmd.startIndex..<bracket])
    } else {
        cmd = rawCmd
    }

    let start = CFAbsoluteTimeGetCurrent()

    // Android-specific commands (not in shared dispatcher)
    switch cmd {

    case "ping":
        let deviceId = try bridge.getBootedDeviceId()
        print("Connected to \(deviceId) (\(elapsedMs(start))ms)")

    case "index":
        let tree = try bridge.tree()
        let index = ElementIndexShared()
        index.build(from: tree)
        if args.count >= 2 {
            let results = index.find(args[1])
            if results.isEmpty {
                print("No elements matching '\(args[1])'")
            } else {
                for entry in results {
                    let idx = "$\(entry.index)".padding(toLength: 5, withPad: " ", startingAt: 0)
                    let role = entry.role.padding(toLength: 14, withPad: " ", startingAt: 0)
                    let label = entry.label.isEmpty ? entry.id : entry.label
                    let display = label.isEmpty ? "(no label)" : "\"\(label)\""
                    print("\(idx) \(role) \(display.padding(toLength: 30, withPad: " ", startingAt: 0)) \(entry.frame)")
                }
                print("\n\(results.count) match(es)")
            }
        } else {
            index.printIndex()
        }
        print("(\(elapsedMs(start))ms)")

    case "inspect":
        guard args.count >= 2 else {
            print("Usage: auto-android inspect <query>")
            return
        }
        let query = args[1].lowercased()
        let tree = try bridge.tree()
        var found = 0
        func inspectNode(_ node: [String: Any], depth: Int) {
            guard depth < 20 else { return }
            let title = (node["title"] as? String) ?? ""
            let label = (node["label"] as? String) ?? ""
            let identifier = (node["identifier"] as? String) ?? ""
            let matches = title.lowercased().contains(query) ||
                         label.lowercased().contains(query) ||
                         identifier.lowercased().contains(query)
            if matches {
                found += 1
                print("--- Match \(found) ---")
                for key in node.keys.sorted() {
                    if key == "children" {
                        let children = node[key] as? [[String: Any]] ?? []
                        print("  \(key): \(children.count) child(ren)")
                    } else {
                        print("  \(key): \(node[key] ?? "nil")")
                    }
                }
                print()
            }
            if let children = node["children"] as? [[String: Any]] {
                for child in children { inspectNode(child, depth: depth + 1) }
            }
        }
        for node in tree { inspectNode(node, depth: 0) }
        if found == 0 { print("No elements matching '\(args[1])'") }
        else { print("\(found) match(es) (\(elapsedMs(start))ms)") }

    case "tap":
        guard args.count >= 2 else {
            print("Usage: auto-android tap <label|$N|label[N]>")
            return
        }
        runAsync { try await AndroidTapEnhancement.execute(args: args, router: router, start: start) }

    case "launch":
        runAsync { try await AndroidLaunchEnhancement.execute(args: args, bridge: bridge, router: router, start: start) }

    case "camera":
        try AndroidCameraCommand.execute(args: args, bridge: bridge, start: start)

    case "inject":
        try AndroidInjectCommand.execute(args: args, bridge: bridge, start: start)

    case "build":
        try AndroidBuildCommand.execute(args: args, start: start)

    case "apps":
        // `auto-android apps` (#187) — paquetes instalados del emulador.
        // Fuente del predictivo de bundleId del editor.
        try AndroidAppsCommand.execute(args: Array(args.dropFirst()), deviceId: nil)

    case "list":
        // `list <type>` → AndroidListCommand via router (ARD-001).
        // `list` sin args → fall-through al shared dispatcher (lista devices).
        if args.count >= 2 {
            let wasHandled = runAsyncReturning {
                try await AndroidListCommand.execute(args: args, router: router, start: start)
            }
            if wasHandled { return }
        }
        // Fall-through a executeSharedCommand para listar devices
        let handled = try executeSharedCommand(args, bridge: bridge, router: router)
        if !handled {
            throw CommandCatalog.unknownCommandError(cmd, extra: androidCommandCatalogExtras)
        }

    case "record":
        guard args.count >= 2 else {
            print("Usage: auto-android record <output.auto>")
            print("Records touch interactions to a .auto script via getevent.")
            return
        }
        let session = AndroidRecordingSession(bridge: bridge, outputPath: args[1])
        try session.start()

        signal(SIGINT, SIG_IGN)
        let sigSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigSource.setEventHandler {
            do {
                let path = try session.stop()
                print("\nSaved to \(path)")
            } catch {
                print("\nError saving: \(error)")
            }
            exit(0)
        }
        sigSource.resume()
        dispatchMain()

    case "help", "--help", "-h":
        AndroidUsage.printUsage()

    case "agent":
        // Ciclo de vida del agente on-device (#135). `stop` libera la conexion
        // UiAutomation para poder usar --legacy tree/tap (benchmark #62);
        // `start` lo relanza; `status` reporta socket + proceso.
        // Se crea un AgentBridge dedicado: el comando debe funcionar igual
        // con o sin --legacy.
        let agent = AgentBridge()
        switch args.count >= 2 ? args[1] : "" {
        case "stop":
            try agent.stopAgent()
            print("(\(elapsedMs(start))ms)")
        case "start":
            try agent.setupAgent()
            print("(\(elapsedMs(start))ms)")
        case "status":
            switch agent.agentStatus() {
            case .running:
                print("Agent running — socket responding (\(elapsedMs(start))ms)")
            case .processOnly:
                print("Agent process alive but socket not responding — run: auto-android setup (\(elapsedMs(start))ms)")
            case .stopped:
                print("Agent stopped — UiAutomation libre para --legacy tree/tap (\(elapsedMs(start))ms)")
            }
        default:
            print("Usage: auto-android agent <stop|start|status>")
            print("  stop    Force-stop the agent (releases UiAutomation for --legacy tree/tap)")
            print("  start   Relaunch the agent via am instrument")
            print("  status  Probe agent socket + process")
        }

    case "setup":
        // Bootstrap completo paridad con iOS: adb + device + apk + agent + warmup.
        // Device actions viajan por el router (ARD-001).
        runAsync { try await AndroidSetup.run(router: router, bridge: bridge) }

    case "doctor":
        AndroidDoctor.run(bridge: bridge, useLegacy: useLegacy)

    default:
        let handled = try executeSharedCommand(args, bridge: bridge, router: router)
        if !handled {
            // Comando no reconocido → error tipado. En modo script el
            // interpreter lo convierte en `FAIL at line N` + exit 1; en uso
            // interactivo `run()` lo captura e imprime el help (#152).
            throw CommandCatalog.unknownCommandError(cmd, extra: androidCommandCatalogExtras)
        }
    }
}

do {
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
