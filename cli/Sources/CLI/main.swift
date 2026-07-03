import Foundation
import AppKit
import ApplicationServices
import AutoCore
import AutoLibiOS

// Bootstrap de plataforma vía iOSDeviceResolver (ARD-001).
// El resolver construye el ActionRouter con los 4 backends nativos registrados,
// y expone los bridges iOS-específicos (simulatorBridge, xcuiBridge) que aún
// consumen los comandos no migrados al router (ping, index, tap con $N, etc).
let deviceResolver = iOSDeviceResolver()
let router = deviceResolver.router
let simulatorBridge = deviceResolver.simulatorBridge
let xcuiBridge = deviceResolver.xcuiBridge
let bridge: any DeviceBridge = deviceResolver.legacyBridge
let stabilizer = UIStabilizer()
let elementIndex = ElementIndex()

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())

    guard let cmd = args.first else {
        iOSUsage.printUsage()
        return
    }

    if cmd == "run" {
        guard args.count >= 2 else {
            print("Usage: auto run <script.auto>")
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
        iOSUsage.printUsage()
        exit(1)
    }
}

/// Comandos que resuelve este main (no están en el shared dispatcher).
/// Alimenta la sugerencia Levenshtein del fallthrough (#152).
let iosCommandCatalogExtras: [String] = [
    "ping", "index", "launch", "camera", "inject", "build", "inspect",
    "record", "stats", "daemon", "runner", "doctor", "setup", "help",
    "run", "interactive",
]

func runScript(path: String) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)

    // Attach stabilizer for auto-wait between steps
    if let pid = simulatorBridge.findSimulatorPID() {
        stabilizer.attach(pid: pid)
    }

    let totalStart = CFAbsoluteTimeGetCurrent()

    // Parse con el parser estructural (soporta if/repeat/try/assert).
    // Scripts sin keywords nuevos se parsean como `.action` plano — 100%
    // backward compatible.
    let statements: [ScriptStatement]
    do {
        statements = try parseStatements(content)
    } catch {
        print("Parse error: \(error)")
        stabilizer.detach()
        exit(1)
    }

    // El interpreter usa el router existente para las primitivas comunes
    // (tap, type, screenshot...) y delega al dispatcher legacy para el resto
    // (ping, index, doctor, camera, config, etc.) vía `onUnknownCommand`.
    let interp = ScriptInterpreter(router: router) { tokens, line in
        // Stabilize antes de ejecutar el comando (como el loop viejo).
        stabilizer.waitForStable(quietPeriod: 0.15, timeout: 3.0)
        stabilizer.resetCounter()
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

    stabilizer.detach()

    if let err = runError {
        print("Script failed: \(err)")
        exit(1)
    }

    let totalMs = elapsedMs(totalStart)
    print("\nScript completed (\(totalMs)ms)")
}

/// Commands that mutate the simulator UI or observe a transition. Running
/// `waitForStable` before one of these avoids half-baked states carried over
/// from a previous animation. Read-only commands (ping, tree, exists,
/// screenshot, list, doctor) don't need it.
private let interactiveMutators: Set<String> = [
    "tap", "doubleTap", "longPress", "tapAt",
    "type", "clear", "eraseText",
    "swipe", "scroll", "scrollTo", "scrollUntilVisible", "drag",
    "pressKey", "hideKeyboard",
    "launch", "terminate", "install", "uninstall", "clearState",
    "rotate", "setAppearance", "lockDevice", "unlockDevice",
    "permission", "openurl", "media", "paste",
    "biometric", "faceid", "setLocation",
    "waitFor", "waitUntilGone",
]

/// REPL that keeps `bridge` and `stabilizer` alive across commands so a client
/// (the editor, a test harness, scripts, etc.) can run a whole .auto flow
/// without paying process cold-start or losing stabilizer state.
///
/// Protocol: newline-delimited JSON. See InteractiveJSON for the exact shape.
func runInteractive() {
    // Attach the stabilizer up-front. If the Simulator isn't running yet the
    // attach is a no-op and the first `launch` will work anyway; we just
    // won't get event-driven stabilization for that very first command.
    if let pid = simulatorBridge.findSimulatorPID() {
        stabilizer.attach(pid: pid)
    }

    // Make stdout line-buffered so every print()+fflush gets flushed promptly
    // to the pipe (the client parses one JSON object per newline).
    setvbuf(stdout, nil, _IOLBF, 0)

    // Emit the banner so the client knows the REPL is alive and warmed up.
    print(InteractiveJSON.ready(platform: "ios"))
    fflush(stdout)

    while let rawLine = readLine(strippingNewline: true) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

        // Empty lines and comments are cheap no-ops so scripts with blank
        // lines / header comments work without any client-side filtering.
        if trimmed.isEmpty || trimmed.hasPrefix("#") {
            print(InteractiveJSON.skipped())
            fflush(stdout)
            continue
        }

        // Explicit exit commands for a clean shutdown.
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

        // Command name sans the [role] suffix, used for stabilizer gating.
        let rawCmd = tokens[0]
        let cmdName: String
        if let bracket = rawCmd.firstIndex(of: "[") {
            cmdName = String(rawCmd[rawCmd.startIndex..<bracket])
        } else {
            cmdName = rawCmd
        }

        if interactiveMutators.contains(cmdName) {
            // Wait for the previous frame's animation to settle. The event-
            // driven stabilizer exits early as soon as `quietPeriod` seconds
            // pass without any AX change, so this is free when the UI is
            // already idle (the typical case after the user waits a beat
            // between script edits). 0.15s tuned empirically — long enough
            // to let an animation finish, short enough to not over-pay on
            // apps with continuous AX event traffic.
            stabilizer.waitForStable(quietPeriod: 0.15, timeout: 3.0)
            stabilizer.resetCounter()
        }

        // Run the existing per-command dispatch with stdout redirected to a
        // pipe so we can wrap its output in a JSON envelope without touching
        // every `case` in executeCommand / executeSharedCommand.
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

    stabilizer.detach()
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

    // iOS-specific commands (not in shared dispatcher)
    switch cmd {

    case "ping":
        // #162: chequear solo el proceso Simulator.app daba falso positivo
        // ("Simulator found" exit 0) con el device apagado. Verificar ambos
        // estados y reportarlos con honestidad.
        let appRunning = simulatorBridge.findSimulatorPID() != nil
        let bootedDevice = try? simulatorBridge.getBootedDeviceId()
        let ms = elapsedMs(start)
        switch (appRunning, bootedDevice) {
        case (true, .some(let udid)):
            print("Simulator app running, device booted: \(udid) (\(ms)ms)")
        case (false, .some(let udid)):
            print("Device booted: \(udid), but Simulator.app is not running — open it for UI commands (\(ms)ms)")
        case (true, .none):
            throw BridgeError.unknown(
                "Simulator.app is running, but no device is booted. Boot one with: xcrun simctl boot <device>"
            )
        case (false, .none):
            throw BridgeError.simulatorNotRunning
        }

    case "index":
        let root = try simulatorBridge.findSimulatorContent()
        elementIndex.rebuild(from: root)
        let ms = elapsedMs(start)
        if args.count >= 2 {
            let matches = elementIndex.find(args[1])
            if matches.isEmpty {
                print("No elements matching '\(args[1])'")
            } else {
                for e in matches {
                    let idx = "$\(e.index)".padding(toLength: 5, withPad: " ", startingAt: 0)
                    let role = e.role.replacingOccurrences(of: "AX", with: "").padding(toLength: 12, withPad: " ", startingAt: 0)
                    let label = e.label.isEmpty ? e.id : e.label
                    print("\(idx) \(role) \"\(label)\"  \(e.frame)")
                }
            }
        } else {
            elementIndex.printIndex()
        }
        print("\n\(elementIndex.count) elements indexed (\(ms)ms)")

    case "tap":
        guard args.count >= 2 else {
            iOSTapEnhancement.printUsage()
            return
        }
        let deps = iOSTapEnhancement.Dependencies(
            simulatorBridge: simulatorBridge,
            elementIndex: elementIndex,
            router: router
        )
        runAsync { try await iOSTapEnhancement.execute(args: args, deps: deps, start: start) }

    case "launch":
        runAsync { try await iOSLaunchEnhancement.execute(args: args, simulatorBridge: simulatorBridge, router: router, start: start) }

    case "camera":
        guard args.count >= 2 else {
            print("Usage: auto camera <start|feed|stop|status> [image]")
            return
        }
        switch args[1] {
        case "start":
            guard args.count >= 3 else {
                print("Usage: auto camera start <image.jpg>")
                return
            }
            try simulatorBridge.cameraStart(imagePath: args[2])
            let ms = elapsedMs(start)
            print("Camera started with '\(args[2])' (\(ms)ms)")
        case "feed":
            guard args.count >= 3 else {
                print("Usage: auto camera feed <image.jpg>")
                return
            }
            try simulatorBridge.cameraFeed(imagePath: args[2])
            let ms = elapsedMs(start)
            print("Camera feed updated: '\(args[2])' (\(ms)ms)")
        case "stop":
            simulatorBridge.cameraStop()
            let ms = elapsedMs(start)
            print("Camera stopped (\(ms)ms)")
        case "status":
            let status = simulatorBridge.cameraStatus()
            let ms = elapsedMs(start)
            if status.active {
                print("ACTIVE — feed: \(status.imagePath ?? "none") (\(ms)ms)")
            } else {
                print("INACTIVE (\(ms)ms)")
            }
        default:
            print("Unknown: \(args[1]). Use start/feed/stop/status")
        }

    case "inject":
        guard args.count >= 2 else {
            print("Usage: auto inject <image.jpg>")
            print("Changes the mock camera image without relaunching the app.")
            return
        }
        try simulatorBridge.setInjectImage(args[1])
        print("Camera image updated → \(SimulatorBridge.injectImagePath)")

    case "build":
        var buildArgs = Array(args.dropFirst())

        if buildArgs.isEmpty {
            let config = AutoPilotConfig.readAll()
            guard let project = config["project"] else {
                print("Usage: auto build <xcodebuild args...>")
                print("   or: auto config project App.xcodeproj")
                print("       auto config scheme App")
                print("       auto build")
                return
            }

            if project.hasSuffix(".xcworkspace") {
                buildArgs += ["-workspace", project]
            } else {
                buildArgs += ["-project", project]
            }
            if let scheme = config["scheme"] { buildArgs += ["-scheme", scheme] }
            buildArgs += ["-sdk", "iphonesimulator"]

            if let device = config["device"] {
                if device.contains("-") && device.count > 20 {
                    buildArgs += ["-destination", "id=\(device)"]
                } else {
                    buildArgs += ["-destination", "platform=iOS Simulator,name=\(device)"]
                }
            } else {
                if let booted = try? bridge.getBootedDeviceId() {
                    buildArgs += ["-destination", "id=\(booted)"]
                }
            }
        }

        try simulatorBridge.buildWithCameraMock(args: buildArgs)
        let ms = elapsedMs(start)
        print("Build completed (\(ms)ms)")

    case "inspect":
        guard args.count >= 2 else {
            print("Usage: auto inspect <query>")
            print("       auto inspect <query> --context   (parent chain + within suggestions)")
            return
        }

        if args.contains("--context") {
            let root = try simulatorBridge.findSimulatorContent()
            let result = AXDebug.inspectWithContext(root: root, query: args[1])
            print(result)
        } else {
            let app = try simulatorBridge.findSimulator()
            let result = AXDebug.inspect(root: app, query: args[1])
            if result.isEmpty {
                print("No matches in AX tree for '\(args[1])'")
                print("Trying full attribute dump...")
                let full = AXDebug.inspect(root: app, query: "", maxDepth: 5)
                let filtered = full.split(separator: "\n").filter { $0.lowercased().contains(args[1].lowercased()) }
                for line in filtered { print(line) }
                if filtered.isEmpty { print("Not found anywhere in AX tree.") }
            } else {
                print(result)
            }
        }

    case "record":
        guard args.count >= 2 else {
            print("Usage: auto record <output.auto>")
            print("Records interactions with the Simulator to a .auto script.")
            return
        }
        let session = RecordingSession(bridge: simulatorBridge, outputPath: args[1])
        try session.start()

        // Graceful Ctrl+C
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

        // Pump run loop for AX events
        dispatchMain()

    case "list":
        // `auto list`                     → legacy: list simulators (via shared dispatcher)
        // `auto list <type>`              → NEW: fast typed UI listing via XCUI
        //    type: all | buttons | labels | textfields | cells | switches | links | images | navbars
        let allowedTypes: Set<String> = [
            "all", "buttons", "labels", "statictexts", "textfields",
            "cells", "switches", "links", "images", "navbars", "navigationbars"
        ]
        if args.count >= 2 {
            let listType = args[1].lowercased()
            if allowedTypes.contains(listType) {
                try handleListCommand(type: listType)
                return
            }
            // Unknown arg → fall through to shared dispatcher (will print usage)
        }
        // No args or unrecognized arg → legacy "list simulators"
        _ = try executeSharedCommand(args, bridge: bridge, deepBridge: xcuiBridge, router: router)

    case "stats":
        if let hybrid = bridge as? HybridBridge {
            print(hybrid.stats())
        } else {
            print("bridge: \(type(of: bridge))")
        }

    case "daemon":
        try iOSDaemonCommand.execute(Array(args.dropFirst()))

    case "runner":
        runAsync { try await iOSRunnerCommand.execute(Array(args.dropFirst()), router: router) }

    case "help", "--help", "-h":
        iOSUsage.printUsage()

    case "doctor":
        iOSDoctor.run(simulatorBridge: simulatorBridge, bridge: bridge)

    case "setup":
        // Bootstrap completo: sim + runner + daemon + warmup.
        // Acciones de device pasan por el router (ARD-001).
        runAsync { try await iOSSetup.run(router: router) }

    default:
        // Delegate to shared (platform-agnostic) dispatcher
        let handled = try executeSharedCommand(args, bridge: bridge, deepBridge: xcuiBridge, router: router)
        if !handled {
            // Comando no reconocido → error tipado. En modo script el
            // interpreter lo convierte en `FAIL at line N` + exit 1; en uso
            // interactivo `run()` lo captura e imprime el help (#152).
            throw CommandCatalog.unknownCommandError(cmd, extra: iosCommandCatalogExtras)
        }
    }
}

// MARK: - List subcommand

/// Prints a typed listing of elements via the XCUI runner.
/// Much faster than `tree deep` because it only materializes the requested type(s).
func handleListCommand(type: String) throws {
    let start = CFAbsoluteTimeGetCurrent()

    // Prefer the observer path (bridge.tree) when the observer is reachable —
    // faster and works on device physical. Fall back to XCUI typed listing
    // only when the observer isn't available (no agentBridge registered).
    let items: [[String: Any]]
    if deviceResolver.agentBridge != nil {
        let tree = try bridge.tree()
        items = filterTreeByListType(tree, type: type)
    } else {
        items = try xcuiBridge.list(type: type)
    }

    let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

    if items.isEmpty {
        print("No elements found for type '\(type)' (\(ms)ms)")
        return
    }

    print("Found \(items.count) element(s) of type '\(type)' (\(ms)ms):\n")
    for item in items {
        let role = item["role"] as? String ?? "?"
        let label = item["label"] as? String ?? ""
        let ident = item["identifier"] as? String ?? ""
        let value = item["value"] as? String ?? ""
        let enabled = item["enabled"] as? Bool ?? true
        let frame = (item["frame"] as? [String: Int]).map {
            "[\($0["x"] ?? 0),\($0["y"] ?? 0) \($0["width"] ?? 0)x\($0["height"] ?? 0)]"
        } ?? ""

        var line = role
        if !label.isEmpty { line += "  label=\"\(label)\"" }
        if !ident.isEmpty { line += "  id=\(ident)" }
        if !value.isEmpty && value != label { line += "  value=\"\(value)\"" }
        if !enabled { line += "  (disabled)" }
        line += "  \(frame)"
        print(line)
    }
}

/// Filter a tree (from DeviceBridge.tree / observer) to entries matching the
/// requested `auto list <type>` filter. Reuses the AX role taxonomy the observer
/// already emits, so we skip the XCUI typed-query roundtrip.
private func filterTreeByListType(_ tree: [[String: Any]], type: String) -> [[String: Any]] {
    let wanted: Set<String>
    switch type.lowercased() {
    case "all":                         return tree
    case "buttons":                     wanted = ["AXButton"]
    case "labels", "statictexts":       wanted = ["AXStaticText"]
    case "textfields":                  wanted = ["AXTextField", "AXTextArea"]
    case "cells":                       wanted = ["AXCell"]
    case "switches":                    wanted = ["AXCheckBox", "AXSwitch"]
    case "links":                       wanted = ["AXLink"]
    case "images":                      wanted = ["AXImage"]
    case "navbars", "navigationbars":   wanted = ["AXNavigationBar"]
    default:                            return []
    }
    return tree.filter { node in
        guard let role = node["role"] as? String else { return false }
        return wanted.contains(role)
    }
}

do {
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
