import Foundation
import AutoCore

let useLegacy = CommandLine.arguments.contains("--legacy")
let bridge: any DeviceBridge = useLegacy ? AdbLegacyBridge() : AgentBridge()

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst().filter { $0 != "--legacy" })

    guard let cmd = args.first else {
        printUsage()
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

func executeCommand(_ args: [String]) throws {
    guard let cmd = args.first else { return }

    let start = CFAbsoluteTimeGetCurrent()

    // Android-specific commands
    switch cmd {

    case "ping":
        let deviceId = try bridge.getBootedDeviceId()
        let ms = elapsedMs(start)
        print("Connected to \(deviceId) (\(ms)ms)")

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
        let ms = elapsedMs(start)
        print("(\(ms)ms)")

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
        let target = args.dropFirst().joined(separator: " ")

        // $N index reference
        if let idx = TargetResolverShared.parseIndex(target) {
            let tree = try bridge.tree()
            let index = ElementIndexShared()
            index.build(from: tree)
            guard let entry = index.get(idx) else {
                print("Index $\(idx) not found (max $\(index.count - 1))")
                return
            }
            // Tap by label through bridge
            let tapTarget = entry.label.isEmpty ? entry.id : entry.label
            try bridge.tap(target: tapTarget)
            print("Tapped $\(idx) '\(tapTarget)' (\(elapsedMs(start))ms)")
            return
        }

        // Label[N] occurrence syntax
        let (label, occurrence) = TargetResolverShared.parse(target)
        if let occ = occurrence {
            let tree = try bridge.tree()
            let matches = TargetResolverShared.findAll(in: tree, matching: label)
            guard let match = matches.first(where: { $0.occurrence == occ }) else {
                print("'\(label)[\(occ)]' not found (\(matches.count) occurrence(s) total)")
                return
            }
            let tapLabel = (match.element["title"] as? String) ?? (match.element["label"] as? String) ?? label
            try bridge.tap(target: tapLabel)
            print("Tapped '\(label)[\(occ)]' (\(elapsedMs(start))ms)")
            return
        }

        // Plain label — delegate to shared
        let handled = try executeSharedCommand(args, bridge: bridge)
        if !handled {
            print("Unknown command: \(cmd)")
        }
        return

    case "launch":
        let config = AutoPilotConfig.readAll()
        guard let parsed = parseLaunchArgs(args, config: config) else {
            print("Usage: auto-android launch <package> [--inject image.jpg]")
            print("   or: auto-android config bundle dev.autopilot.test.Explorea")
            print("       auto-android launch")
            return
        }

        if let injectImg = parsed.injectImage {
            guard let agent = bridge as? AgentBridge else {
                print("Error: --inject requires agent bridge (not --legacy)")
                return
            }
            var imgPath = injectImg
            if !imgPath.hasPrefix("/") {
                imgPath = FileManager.default.currentDirectoryPath + "/" + imgPath
            }
            try agent.injectAndLaunch(bundleId: parsed.bundleId, imagePath: imgPath)
            let ms = elapsedMs(start)
            print("Launched \(parsed.bundleId) with camera mock → \(imgPath) (\(ms)ms)")
        } else {
            try bridge.launchApp(bundleId: parsed.bundleId, envVars: [:])
            let ms = elapsedMs(start)
            print("Launched \(parsed.bundleId) (\(ms)ms)")
        }

    case "camera":
        guard args.count >= 2 else {
            print("Usage: auto-android camera <start|feed|stop> [image] [--package <pkg>]")
            return
        }
        guard let agent = bridge as? AgentBridge else {
            print("Error: camera mock requires agent bridge (not --legacy)")
            return
        }

        // Resolve package from --package flag or .autopilot config
        let pkgFlag: String? = {
            if let idx = args.firstIndex(of: "--package"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }()
        let config = AutoPilotConfig.readAll()
        guard let package = pkgFlag ?? config["bundle"] else {
            print("Error: no package specified. Use --package <pkg> or set: auto-android config bundle <pkg>")
            return
        }

        // Filter out --package flag from positional args
        let cameraArgs = args.filter { $0 != "--package" && $0 != package }

        switch cameraArgs.count >= 2 ? cameraArgs[1] : "" {
        case "start":
            guard cameraArgs.count >= 3 else {
                print("Usage: auto-android camera start <image.jpg> [--package <pkg>]")
                return
            }
            try agent.cameraStart(imagePath: cameraArgs[2], package: package)
            let ms = elapsedMs(start)
            print("Camera mock injected into \(package) with '\(cameraArgs[2])' (\(ms)ms)")
        case "feed":
            guard cameraArgs.count >= 3 else {
                print("Usage: auto-android camera feed <image.jpg> [--package <pkg>]")
                return
            }
            try agent.cameraFeed(imagePath: cameraArgs[2], package: package)
            let ms = elapsedMs(start)
            print("Camera feed updated: '\(cameraArgs[2])' (\(ms)ms)")
        case "stop":
            try agent.cameraStop(package: package)
            let ms = elapsedMs(start)
            print("Camera stopped for \(package) (\(ms)ms)")
        default:
            print("Unknown camera action: \(args[1]). Use start/feed/stop")
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
    AutoPilot Android — Android device automation via native agent

    Usage: auto-android <command> [arguments]
           auto-android --legacy <command>   (use slow adb bridge for benchmarks)

    Commands:
      ping                              Check ADB connection
      tree                              Print accessibility tree
      tree -s "query"                   Search elements
      index [query]                     List indexed elements ($N syntax)
      inspect <query>                   Deep element inspection
      launch <package> [--inject img]    Launch app (--inject for camera mock)
      tap <label|$N|label[N]>           Tap element (supports $N and Label[2])
      longPress <text|desc|id> [secs]   Long press element
      doubleTap <text|desc|id>          Double tap element
      clear <text|desc|id>              Clear text field
      type [target] <text>              Type text
      scroll <text|desc|id> <direction> Scroll element
      swipe <up|down|left|right>        Swipe
      exists <text|desc|id>             Check if element exists
      list                              List devices
      install <path/to/app.apk>        Install APK
      elementAt <x> <y>                 Element at coordinate
      screenshot [filename.png]         Screenshot
      biometric <enroll|match|fail|status> Biometric control
      paste [text]                      Set/get clipboard
      camera start <image.jpg> [--package <pkg>]  Inject mock camera (JVMTI)
      camera feed <image.jpg> [--package <pkg>]  Update camera image (hot-swap)
      camera stop [--package <pkg>]              Stop mock camera (kills app)
      drag <from> <to> [secs]            Drag between elements
      drag x1,y1 x2,y2 [secs]           Drag between coordinates
      rotate <left|right|portrait|landscape>  Rotate device orientation
      pressKey <key>                     Press key (home, back, enter, delete, volumeUp, volumeDown, power)
      hideKeyboard                       Dismiss on-screen keyboard
      eraseText [N]                      Delete N characters (default 1)
      copyTextFrom <element>             Read text content from element
      clearState <package>               Clear app data (pm clear)
      uninstall <package>                Uninstall app
      scrollTo <element> [direction]     Scroll until element is visible
      startRecording                     Start screen recording
      stopRecording <file.mp4>           Stop recording and save
      setLocation <lat> <lon>            Set GPS location (emulator only)
      setAppearance <dark|light>         Switch dark/light mode
      lockDevice                         Lock device screen
      unlockDevice                       Unlock device screen
      pushFile <local> <remote>          Push file to device
      pullFile <remote> <local>          Pull file from device
      terminate <package>               Kill app
      config                            Show all config
      config <key> <value>              Set config value
      run <script.auto>                 Run automation script

    Script format (.auto):
      # Comments start with #
      launch dev.autopilot.test.Explorea
      waitFor "Explorea"
      tap "Desbloquear con biometría"
      screenshot result.png

    Examples:
      auto-android launch dev.autopilot.test.Explorea
      auto-android tap "Explorea"
      auto-android tree -s "Login"
      auto-android swipe down
      auto-android run test-flow.auto

    Flags:
      --legacy                          Use slow adb bridge (for benchmarks)

    Requirements:
      - ADB installed (ANDROID_HOME or in PATH)
      - Device/emulator connected (adb devices)
      - AutoPilot agent installed (adb install agent.apk)
      - Agent running (adb shell am instrument -w dev.autopilot.agent/.AgentInstrumentation)
      - Socket forwarded (adb forward tcp:9008 localabstract:autopilot)
    """)
}

do {
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
