import Foundation
import AppKit
import ApplicationServices
import AutoCore
import AutoLibiOS

// SimulatorBridge is always available for iOS-specific operations (AX, ping, index, etc.)
let simulatorBridge = SimulatorBridge()
// Dedicated deep bridge for `tree deep` / `tree full` — separate from the default
// bridge so the user can opt-in to deep view even when AUTO_BRIDGE=simulator.
let xcuiBridge = XCUIBridge()
let bridge: DeviceBridge = makeBridge(simulatorBridge)
let stabilizer = UIStabilizer()
let elementIndex = ElementIndex()

func makeBridge(_ simBridge: SimulatorBridge) -> DeviceBridge {
    let mode = ProcessInfo.processInfo.environment["AUTO_BRIDGE"] ?? "hybrid"
    switch mode {
    case "simulator":
        return simBridge
    case "xcui":
        return XCUIBridge()
    case "hybrid":
        return HybridBridge(fast: simBridge, deep: XCUIBridge())
    default:
        return HybridBridge(fast: simBridge, deep: XCUIBridge())
    }
}

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())

    guard let cmd = args.first else {
        printUsage()
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

    try executeCommand(args)
}

func runScript(path: String) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let steps = parseScript(content)

    // Attach stabilizer for auto-wait between steps
    if let pid = simulatorBridge.findSimulatorPID() {
        stabilizer.attach(pid: pid)
    }

    let totalStart = CFAbsoluteTimeGetCurrent()

    for (i, step) in steps.enumerated() {
        let label = step.tokens.joined(separator: " ")
        print("[\(i + 1)] \(label)")

        // Auto-wait: let UI stabilize before each action
        stabilizer.waitForStable(quietPeriod: 0.15, timeout: 3.0)
        stabilizer.resetCounter()

        do {
            try executeCommand(step.tokens)
        } catch {
            print("FAIL at line \(step.lineNumber): \(error)")
            exit(1)
        }
    }

    stabilizer.detach()
    let totalMs = elapsedMs(totalStart)
    print("\n\(steps.count) step(s) completed (\(totalMs)ms)")
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
        let _ = try simulatorBridge.findSimulator()
        let ms = elapsedMs(start)
        print("Simulator found (\(ms)ms)")

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
        // iOS-enhanced tap: supports $N, label[N], tap[role], within
        guard args.count >= 2 else {
            print("Usage: auto tap <label>")
            print("       auto tap Camera[2]           (second Camera)")
            print("       auto tap $N                  (by index)")
            print("       auto tap a,b,c               (multiple)")
            print("       auto tap[button] \"label\"      (role verification)")
            print("       auto tap \"label\" within \"scope\"  (scoped search)")
            return
        }

        // New path: role and/or within syntax
        if let parsed = parseCommand(args), (parsed.role != nil || parsed.within != nil) {
            let element = try simulatorBridge.findAXElementScoped(
                target: parsed.target, role: parsed.role, within: parsed.within
            )
            simulatorBridge.tapElement(element)
            var desc = "Tapped '\(parsed.target)'"
            if let role = parsed.role { desc += " [\(role)]" }
            if let within = parsed.within { desc += " within '\(within)'" }
            print("\(desc) (\(elapsedMs(start))ms)")
            break
        }

        // Existing path: $N, label[N], comma-separated
        let targets = args[1].split(separator: ",").map(String.init)
        for target in targets {
            // $N syntax — resolve by element index
            if target.hasPrefix("$"), let n = Int(target.dropFirst()) {
                if elementIndex.count == 0 {
                    let root = try simulatorBridge.findSimulatorContent()
                    elementIndex.rebuild(from: root)
                }
                guard let entry = elementIndex.get(n) else {
                    print("Index $\(n) out of range (0..\(elementIndex.count - 1))")
                    return
                }
                AXUIElementPerformAction(entry.element, kAXPressAction as CFString)
                let label = entry.label.isEmpty ? entry.id : entry.label
                print("Tapped $\(n) '\(label)' (\(elapsedMs(start))ms)")
            } else {
                // Parse label[N] syntax
                let (label, occurrence) = TargetResolver.parse(target)

                if let occurrence {
                    let root = try simulatorBridge.findSimulatorContent()
                    let matches = TargetResolver.findAll(in: root, matching: label)
                    guard occurrence >= 1 && occurrence <= matches.count else {
                        if matches.isEmpty {
                            print("No elements matching '\(label)'")
                        } else {
                            print("'\(label)' has \(matches.count) match(es), requested [\(occurrence)]")
                        }
                        return
                    }
                    let (element, _) = matches[occurrence - 1]
                    AXUIElementPerformAction(element, kAXPressAction as CFString)
                    print("Tapped '\(label)[\(occurrence)]' (\(elapsedMs(start))ms)")
                } else {
                    try bridge.tap(target: target)
                    print("Tapped '\(target)' (\(elapsedMs(start))ms)")
                }
            }
        }

    case "launch":
        let config = AutoPilotConfig.readAll()
        let bundleId: String
        if args.count >= 2 && !args[1].hasPrefix("--") {
            bundleId = args[1]
        } else if let b = config["bundle"] {
            bundleId = b
        } else {
            print("Usage: auto launch <bundleId> [--inject image.jpg] [--env KEY=VALUE ...]")
            print("   or: auto config bundle com.example.app")
            print("       auto launch")
            return
        }

        var envVars: [String: String] = [:]
        var injectImage: String? = nil
        var recompile = false

        // Auto-inject camera image from config
        if let img = config["image"] {
            envVars["AUTOPILOT_CAMERA_IMAGE"] = img
        }

        var i = args.count >= 2 && !args[1].hasPrefix("--") ? 2 : 1
        while i < args.count {
            if args[i] == "--env" && i + 1 < args.count {
                let pair = args[i + 1]
                if let eqIndex = pair.firstIndex(of: "=") {
                    let key = String(pair[pair.startIndex..<eqIndex])
                    let value = String(pair[pair.index(after: eqIndex)...])
                    envVars[key] = value
                }
                i += 2
            } else if args[i] == "--inject" {
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    injectImage = args[i + 1]
                    i += 2
                } else {
                    injectImage = config["image"]
                    i += 1
                }
            } else if args[i] == "--recompile" {
                recompile = true
                i += 1
            } else {
                i += 1
            }
        }

        if let injectImg = injectImage {
            var imgPath = injectImg
            if !imgPath.hasPrefix("/") {
                imgPath = FileManager.default.currentDirectoryPath + "/" + imgPath
            }

            if recompile {
                let injector = DylibInjector()
                try injector.recompile()
            }

            try simulatorBridge.injectAndLaunch(bundleId: bundleId, imagePath: imgPath, extraEnv: envVars)
            let ms = elapsedMs(start)
            print("Launched \(bundleId) with camera mock → \(imgPath) (\(ms)ms)")
        } else {
            try bridge.launchApp(bundleId: bundleId, envVars: envVars)
            let ms = elapsedMs(start)
            if envVars.isEmpty {
                print("Launched \(bundleId) (\(ms)ms)")
            } else {
                print("Launched \(bundleId) with \(envVars.count) env var(s) (\(ms)ms)")
            }
        }

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
        _ = try executeSharedCommand(args, bridge: bridge, deepBridge: xcuiBridge)

    case "stats":
        if let hybrid = bridge as? HybridBridge {
            print(hybrid.stats())
        } else {
            print("bridge: \(type(of: bridge))")
        }

    case "daemon":
        try handleDaemonCommand(Array(args.dropFirst()))

    case "runner":
        try handleRunnerCommand(Array(args.dropFirst()))

    case "help", "--help", "-h":
        printUsage()

    case "doctor":
        print("AutoPilot Doctor — iOS Environment Check\n")

        // 1. Simulator.app running
        print("Simulator.app:")
        if let pid = simulatorBridge.findSimulatorPID() {
            print("  ✓ Running (PID \(pid))")
        } else {
            print("  ✗ Not running — open Simulator.app first")
        }

        // 2. Booted simulator
        print("\nBooted Simulator:")
        do {
            let deviceId = try bridge.getBootedDeviceId()
            print("  ✓ \(deviceId)")
        } catch {
            print("  ✗ No booted simulator — run: xcrun simctl boot <device>")
        }

        // 3. xcrun
        print("\nxcrun:")
        let xcrunCheck = Process()
        xcrunCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrunCheck.arguments = ["--version"]
        let xcrunPipe = Pipe()
        xcrunCheck.standardOutput = xcrunPipe
        xcrunCheck.standardError = Pipe()
        try? xcrunCheck.run()
        xcrunCheck.waitUntilExit()
        if xcrunCheck.terminationStatus == 0 {
            let ver = (String(data: xcrunPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            print("  ✓ Found (\(ver))")
        } else {
            print("  ✗ xcrun not working — install Xcode Command Line Tools")
        }

        // 4. Accessibility
        print("\nAccessibility Permission:")
        if AXIsProcessTrusted() {
            print("  ✓ Granted")
        } else {
            print("  ✗ Not granted — add this app to: System Settings > Privacy & Security > Accessibility")
        }

        // 5. Environment
        print("\nEnvironment:")
        print("  PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(not set)")")
        print("  DEVELOPER_DIR: \(ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "(not set)")")

    default:
        // Delegate to shared (platform-agnostic) dispatcher
        let handled = try executeSharedCommand(args, bridge: bridge, deepBridge: xcuiBridge)
        if !handled {
            print("Unknown command: \(cmd)")
            printUsage()
        }
    }
}

func printUsage() {
    print("""
    AutoPilot — iOS Simulator automation

    Usage: auto <command> [arguments]

    Commands:
      ping                              Check Simulator is running
      tree                              Print accessibility tree
      tree -s "query"                   Search elements
      tree deep                         Deep tree via XCUI runner (slow, sees NavBar SwiftUI)
      tree full                         Fast + deep tree side by side
      list <type>                       Fast typed UI listing via XCUI runner (~1s vs 13s tree deep)
                                        type: all | buttons | labels | textfields | cells |
                                              switches | links | images | navbars
                                        (sin args → lista simuladores, ver abajo)
      launch <bundleId> [--inject img]   Launch app (--inject for camera mock)
      tap <id|title|label>              Tap element
      tap[role] "label" within "scope"  Tap with role verification + scoped search
      longPress <id|title|label> [secs]  Long press element
      doubleTap <id|title|label>        Double tap element
      clear <id|title|label>            Clear text field
      type [target] <text>              Type text
      scroll <id|label> <direction>     Scroll element
      swipe <up|down|left|right>        Swipe
      drag <from> <to> [secs]            Drag between elements (default 0.5s)
      drag x1,y1 x2,y2 [secs]           Drag between coordinates
      exists <id|title|label>           Check if element exists
      list                              List simulators
      boot <name|udid>                  Boot simulator
      shutdown <name|udid>              Shutdown simulator
      install <path/to/app.app>        Install app on simulator
      elementAt <x> <y>                 Element at coordinate
      screenshot [filename.png]         Screenshot (via simctl)
      inspect <query> --context           Parent chain + within suggestions
      inject <image.jpg>                 Change mock camera image (hot-swap)
      camera start <image>              Start virtual camera feed
      camera feed <image>               Update camera image
      camera stop                       Stop virtual camera
      camera status                     Check camera status
      terminate <bundleId>              Kill app
      permission <grant|revoke|reset> <service> <bundleId>  Manage app permissions
      logs [bundleId] [--lines N]       Get device logs (last 50 lines)
      logs --system                     Get system logs
      rotate <left|right|portrait|landscape>  Rotate device orientation
      pressKey <key>                     Press hardware key (home, enter, delete, tab, escape, volumeUp, volumeDown)
      hideKeyboard                       Dismiss on-screen keyboard
      eraseText [N]                      Delete N characters (default 1)
      copyTextFrom <element>             Read text content from element
      clearState <bundleId>              Clear app data and permissions
      uninstall <bundleId>               Uninstall app from simulator
      waitUntilGone <label> [timeout]     Wait for element to disappear
      scrollTo <element> [direction]     Scroll until element is visible in viewport
      scrollUntilVisible <element> [dir] Alias of scrollTo (semantic name, emitted by recorder)
      startRecording                     Start screen recording
      stopRecording <file.mp4>           Stop recording and save
      setLocation <lat> <lon>            Set simulated GPS location
      setAppearance <dark|light>         Switch dark/light mode
      lockDevice                         Lock device screen
      unlockDevice                       Unlock device screen
      pushFile <local> <remote>          Push file to device
      pullFile <remote> <local>          Pull file from device
      config                             Show all config
      config <key> <value>              Set config value
      config <key>                      Get config value
      build                             Build with camera mock (uses .autopilot)
      build <xcodebuild args...>        Build with explicit args
      record <output.auto>               Record interactions to script (Ctrl+C to stop)
      run <script.auto>                 Run automation script
      doctor                            Check environment setup (Simulator, AX, xcrun)
      daemon start [--udid U] [--timeout S]  Start sidecar daemon for XCTest runner
      daemon stop [--udid U]             Stop sidecar daemon
      daemon status [--udid U]           Show daemon and runner status
      runner install <Runner.app> [--udid U]  Install XCTest runner bundle
      runner status                      Show installed runner info

    Script format (.auto):
      # Comments start with #
      launch com.example.app
      waitFor "Login"
      tap "Username"
      type "user@test.com"
      screenshot result.png

    Examples:
      auto launch com.apple.Preferences
      auto tap "General"
      auto tap[button] "Login"
      auto tap "Camera" within "Toolbar"
      auto tap[button] "Camera[2]" within "Toolbar"
      auto inspect "Camera" --context
      auto tree -s "Información"
      auto swipe down
      auto run test-flow.auto

    Requirements:
      - Simulator.app must be running
      - Accessibility permissions (System Settings > Privacy > Accessibility)
    """)
}

// MARK: - Daemon subcommand

// MARK: - List subcommand

/// Prints a typed listing of elements via the XCUI runner.
/// Much faster than `tree deep` because it only materializes the requested type(s).
func handleListCommand(type: String) throws {
    let start = CFAbsoluteTimeGetCurrent()
    let items = try xcuiBridge.list(type: type)
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

func handleDaemonCommand(_ args: [String]) throws {
    guard let sub = args.first, ["start", "stop", "status"].contains(sub) else {
        print("Usage: auto daemon <start|stop|status> [--udid <UDID>] [--timeout <seconds>]")
        return
    }

    // Locate the autopilotd binary next to auto
    let autoPath = CommandLine.arguments[0]
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
            // UDID: alphanumeric + hyphens only
            let udid = remaining[i + 1]
            let safe = udid.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            guard safe, udid.count <= 40 else {
                print("error: invalid UDID format")
                return
            }
            sanitizedArgs += ["--udid", udid]
            i += 2
        } else if arg == "--timeout", i + 1 < remaining.count {
            guard let _ = Double(remaining[i + 1]) else {
                print("error: --timeout must be a number")
                return
            }
            sanitizedArgs += ["--timeout", remaining[i + 1]]
            i += 2
        } else {
            i += 1 // skip unknown flags
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

// MARK: - Runner subcommand

func handleRunnerCommand(_ args: [String]) throws {
    guard let sub = args.first, ["install", "status"].contains(sub) else {
        print("Usage: auto runner <install|status>")
        return
    }

    let installer = RunnerInstaller()

    switch sub {
    case "install":
        guard args.count >= 2 else {
            print("Usage: auto runner install <path/to/Runner.app> [--udid <UDID>]")
            return
        }
        let bundlePath = args[1]
        // Validate bundle path exists and is a directory
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: bundlePath, isDirectory: &isDir), isDir.boolValue else {
            print("error: \(bundlePath) does not exist or is not a directory")
            return
        }

        let udid: String
        if let udidIdx = args.firstIndex(of: "--udid"), udidIdx + 1 < args.count {
            let raw = args[udidIdx + 1]
            guard raw.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }), raw.count <= 40 else {
                print("error: invalid UDID format")
                return
            }
            udid = raw
        } else {
            udid = try bridge.getBootedDeviceId()
        }
        let result = try installer.installIfNeeded(sourceBundlePath: bundlePath, udid: udid)
        print("installed: \(result.appPath)")
        print("xctestrun: \(result.xctestRunPath)")
        print("version: \(result.version.prefix(8))")

    case "status":
        let baseDir = RunnerInstaller.runnerBaseDir
        let hashFile = RunnerInstaller.hashFile
        if let hash = try? String(contentsOfFile: hashFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) {
            print("runner: installed (hash=\(hash.prefix(8)))")
            print("path: \(baseDir)")
        } else {
            print("runner: not installed")
            print("hint: auto runner install <path/to/Runner.app>")
        }

    default:
        break
    }
}

do {
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
