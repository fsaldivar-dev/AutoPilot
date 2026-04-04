import Foundation
import AppKit
import ApplicationServices
import AutoCore
import AutoLibiOS

let bridge = SimulatorBridge()
let stabilizer = UIStabilizer()
let elementIndex = ElementIndex()

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

    try executeCommand(args)
}

func runScript(path: String) throws {
    let content = try String(contentsOfFile: path, encoding: .utf8)
    let steps = parseScript(content)

    // Attach stabilizer for auto-wait between steps
    if let pid = bridge.findSimulatorPID() {
        stabilizer.attach(pid: pid)
    }

    let totalStart = CFAbsoluteTimeGetCurrent()

    for (i, step) in steps.enumerated() {
        let label = step.tokens.joined(separator: " ")
        print("[\(i + 1)] \(label)")

        // Auto-wait: let UI stabilize before each action
        stabilizer.waitForStable(quietPeriod: 0.3, timeout: 3.0)
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

func executeCommand(_ args: [String]) throws {
    guard let cmd = args.first else { return }

    let start = CFAbsoluteTimeGetCurrent()

    // iOS-specific commands (not in shared dispatcher)
    switch cmd {

    case "ping":
        let _ = try bridge.findSimulator()
        let ms = elapsedMs(start)
        print("Simulator found (\(ms)ms)")

    case "index":
        let root = try bridge.findSimulatorContent()
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
        // iOS-enhanced tap: supports $N index and label[N] occurrence syntax
        guard args.count >= 2 else {
            print("Usage: auto tap <label>")
            print("       auto tap Camera[2]  (second Camera)")
            print("       auto tap $N         (by index)")
            print("       auto tap a,b,c      (multiple)")
            return
        }
        let targets = args[1].split(separator: ",").map(String.init)
        for target in targets {
            // $N syntax — resolve by element index
            if target.hasPrefix("$"), let n = Int(target.dropFirst()) {
                if elementIndex.count == 0 {
                    let root = try bridge.findSimulatorContent()
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
                    let root = try bridge.findSimulatorContent()
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

            try bridge.injectAndLaunch(bundleId: bundleId, imagePath: imgPath, extraEnv: envVars)
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
            try bridge.cameraStart(imagePath: args[2])
            let ms = elapsedMs(start)
            print("Camera started with '\(args[2])' (\(ms)ms)")
        case "feed":
            guard args.count >= 3 else {
                print("Usage: auto camera feed <image.jpg>")
                return
            }
            try bridge.cameraFeed(imagePath: args[2])
            let ms = elapsedMs(start)
            print("Camera feed updated: '\(args[2])' (\(ms)ms)")
        case "stop":
            bridge.cameraStop()
            let ms = elapsedMs(start)
            print("Camera stopped (\(ms)ms)")
        case "status":
            let status = bridge.cameraStatus()
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
        try bridge.setInjectImage(args[1])
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

        try bridge.buildWithCameraMock(args: buildArgs)
        let ms = elapsedMs(start)
        print("Build completed (\(ms)ms)")

    case "inspect":
        guard args.count >= 2 else {
            print("Usage: auto inspect <query>")
            return
        }
        let app = try bridge.findSimulator()
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

    case "help", "--help", "-h":
        printUsage()

    default:
        // Delegate to shared (platform-agnostic) dispatcher
        let handled = try executeSharedCommand(args, bridge: bridge)
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
      launch <bundleId> [--inject img]   Launch app (--inject for camera mock)
      tap <id|title|label>              Tap element
      longPress <id|title|label> [secs]  Long press element
      doubleTap <id|title|label>        Double tap element
      clear <id|title|label>            Clear text field
      type [target] <text>              Type text
      scroll <id|label> <direction>     Scroll element
      swipe <up|down|left|right>        Swipe
      exists <id|title|label>           Check if element exists
      list                              List simulators
      boot <name|udid>                  Boot simulator
      shutdown <name|udid>              Shutdown simulator
      install <path/to/app.app>        Install app on simulator
      elementAt <x> <y>                 Element at coordinate
      screenshot [filename.png]         Screenshot (via simctl)
      inject <image.jpg>                 Change mock camera image (hot-swap)
      camera start <image>              Start virtual camera feed
      camera feed <image>               Update camera image
      camera stop                       Stop virtual camera
      camera status                     Check camera status
      terminate <bundleId>              Kill app
      logs [bundleId] [--lines N]       Get device logs (last 50 lines)
      logs --system                     Get system logs
      config                             Show all config
      config <key> <value>              Set config value
      config <key>                      Get config value
      build                             Build with camera mock (uses .autopilot)
      build <xcodebuild args...>        Build with explicit args
      run <script.auto>                 Run automation script

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
      auto tree -s "Información"
      auto swipe down
      auto run test-flow.auto

    Requirements:
      - Simulator.app must be running
      - Accessibility permissions (System Settings > Privacy > Accessibility)
    """)
}

do {
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
