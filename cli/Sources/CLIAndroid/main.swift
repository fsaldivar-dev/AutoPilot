import Foundation
import AutoCore

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

    try executeCommand(args)
}

func runScript(path: String) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let steps = parseScript(content)

    let totalStart = CFAbsoluteTimeGetCurrent()

    for (i, step) in steps.enumerated() {
        let label = step.tokens.joined(separator: " ")
        print("[\(i + 1)] \(label)")

        do {
            try executeCommand(step.tokens)
        } catch {
            print("FAIL at line \(step.lineNumber): \(error)")
            exit(1)
        }
    }

    let totalMs = elapsedMs(totalStart)
    print("\n\(steps.count) step(s) completed (\(totalMs)ms)")
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
        // TODO(ARD-001): migrate Android dispatcher to pass router (follow-up PR).
        let handled = try executeSharedCommand(args, bridge: bridge, router: nil)
        if !handled {
            print("Unknown command: \(cmd)")
            AndroidUsage.printUsage()
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

    case "setup":
        // Bootstrap completo paridad con iOS: adb + device + apk + agent + warmup.
        // Device actions viajan por el router (ARD-001).
        runAsync { try await AndroidSetup.run(router: router, bridge: bridge) }

    case "doctor":
        AndroidDoctor.run(bridge: bridge, useLegacy: useLegacy)

    default:
        let handled = try executeSharedCommand(args, bridge: bridge)
        if !handled {
            print("Unknown command: \(cmd)")
            AndroidUsage.printUsage()
        }
    }
}

do {
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
