import Foundation
import AutoCore

let bridge = AdbBridge()

func run() throws {
    let args = Array(CommandLine.arguments.dropFirst())

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

    case "launch":
        let config = AutoPilotConfig.readAll()
        let bundleId: String
        if args.count >= 2 && !args[1].hasPrefix("--") {
            bundleId = args[1]
        } else if let b = config["bundle"] {
            bundleId = b
        } else {
            print("Usage: auto-android launch <package>")
            print("   or: auto-android config bundle shajaru.Test_Automatitacion")
            print("       auto-android launch")
            return
        }

        try bridge.launchApp(bundleId: bundleId, envVars: [:])
        let ms = elapsedMs(start)
        print("Launched \(bundleId) (\(ms)ms)")

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
    AutoPilot Android — Android device automation via ADB

    Usage: auto-android <command> [arguments]

    Commands:
      ping                              Check ADB connection
      tree                              Print accessibility tree
      tree -s "query"                   Search elements
      launch <package>                  Launch app
      tap <text|desc|id>                Tap element
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
      terminate <package>               Kill app
      config                            Show all config
      config <key> <value>              Set config value
      run <script.auto>                 Run automation script

    Script format (.auto):
      # Comments start with #
      launch shajaru.Test_Automatitacion
      waitFor "Explorea"
      tap "Desbloquear con biometrico"
      screenshot result.png

    Examples:
      auto-android launch shajaru.Test_Automatitacion
      auto-android tap "Explorea"
      auto-android tree -s "Login"
      auto-android swipe down
      auto-android run test-flow.auto

    Requirements:
      - ADB installed (ANDROID_HOME or in PATH)
      - Device/emulator connected (adb devices)
    """)
}

do {
    try run()
} catch {
    print("Error: \(error)")
    exit(1)
}
