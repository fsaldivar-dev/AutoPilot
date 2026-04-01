import Foundation
import AppKit
import AutoLib

let bridge = SimulatorBridge()

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

    let totalMs = elapsed(totalStart)
    print("\n\(steps.count) step(s) completed (\(totalMs)ms)")
}

func executeCommand(_ args: [String]) throws {
    guard let cmd = args.first else { return }

    let start = CFAbsoluteTimeGetCurrent()

    switch cmd {

    case "ping":
        let _ = try bridge.findSimulator()
        let ms = elapsed(start)
        print("Simulator found (\(ms)ms)")

    case "tree":
        if args.count >= 3 && (args[1] == "--search" || args[1] == "-s") {
            let results = try bridge.search(query: args[2])
            let ms = elapsed(start)
            if results.isEmpty {
                print("No elements found matching '\(args[2])'")
            } else {
                print("Found \(results.count) element(s) matching '\(args[2])' (\(ms)ms):\n")
                for el in results {
                    printElement(el)
                }
            }
        } else {
            let tree = try bridge.tree()
            let ms = elapsed(start)
            TreePrinter.printAX(tree)
            print("\n(\(ms)ms)")
        }

    case "launch":
        guard args.count >= 2 else {
            print("Usage: auto launch <bundleId>")
            return
        }
        try bridge.launchApp(bundleId: args[1])
        let ms = elapsed(start)
        print("Launched \(args[1]) (\(ms)ms)")

    case "tap":
        guard args.count >= 2 else {
            print("Usage: auto tap <identifier|title|label>")
            return
        }
        try bridge.tap(target: args[1])
        let ms = elapsed(start)
        print("Tapped '\(args[1])' (\(ms)ms)")

    case "longPress":
        guard args.count >= 2 else {
            print("Usage: auto longPress <identifier|title|label> [seconds]")
            return
        }
        let duration = args.count >= 3 ? Double(args[2]) ?? 1.0 : 1.0
        try bridge.longPress(target: args[1], duration: duration)
        let ms = elapsed(start)
        print("Long pressed '\(args[1])' for \(duration)s (\(ms)ms)")

    case "doubleTap":
        guard args.count >= 2 else {
            print("Usage: auto doubleTap <identifier|title|label>")
            return
        }
        try bridge.doubleTap(target: args[1])
        let ms = elapsed(start)
        print("Double tapped '\(args[1])' (\(ms)ms)")

    case "clear":
        guard args.count >= 2 else {
            print("Usage: auto clear <identifier|title|label>")
            return
        }
        try bridge.clear(target: args[1])
        let ms = elapsed(start)
        print("Cleared '\(args[1])' (\(ms)ms)")

    case "type":
        guard args.count >= 2 else {
            print("Usage: auto type <text>")
            return
        }
        if args.count >= 3 {
            try bridge.tap(target: args[1])
            usleep(200_000)
            try bridge.typeText(args[2])
        } else {
            try bridge.typeText(args[1])
        }
        let ms = elapsed(start)
        print("Typed text (\(ms)ms)")

    case "scroll":
        guard args.count >= 3 else {
            print("Usage: auto scroll <identifier|title|label> <up|down|left|right>")
            return
        }
        try bridge.scroll(target: args[1], direction: args[2])
        let ms = elapsed(start)
        print("Scrolled '\(args[1])' \(args[2]) (\(ms)ms)")

    case "swipe":
        guard args.count >= 2 else {
            print("Usage: auto swipe <up|down|left|right>")
            return
        }
        try bridge.swipe(direction: args[1])
        let ms = elapsed(start)
        print("Swiped \(args[1]) (\(ms)ms)")

    case "screenshot":
        let filename = args.count >= 2 ? args[1] : "screenshot.png"
        try bridge.screenshot(path: filename)
        let ms = elapsed(start)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filename)[.size] as? Int) ?? 0
        print("Saved: \(filename) (\(fileSize / 1024)KB, \(ms)ms)")

    case "exists":
        guard args.count >= 2 else {
            print("Usage: auto exists <identifier|title|label>")
            return
        }
        let results = try bridge.search(query: args[1])
        let ms = elapsed(start)
        print(results.isEmpty ? "NO (\(ms)ms)" : "YES (\(ms)ms)")

    case "terminate":
        guard args.count >= 2 else {
            print("Usage: auto terminate <bundleId>")
            return
        }
        try bridge.terminateApp(bundleId: args[1])
        let ms = elapsed(start)
        print("Terminated \(args[1]) (\(ms)ms)")

    case "elementAt":
        guard args.count >= 3,
              let x = Double(args[1]),
              let y = Double(args[2]) else {
            print("Usage: auto elementAt <x> <y>")
            return
        }
        if let el = try bridge.elementAt(x: x, y: y) {
            printElement(el)
        } else {
            print("No element at (\(args[1]), \(args[2]))")
        }

    case "tapAt":
        guard args.count >= 3,
              let x = Double(args[1]),
              let y = Double(args[2]) else {
            print("Usage: auto tapAt <x> <y>")
            return
        }
        try bridge.tapAtCoordinate(x: x, y: y)
        let ms = elapsed(start)
        print("Tapped at (\(args[1]), \(args[2])) (\(ms)ms)")

    case "media":
        guard args.count >= 2 else {
            print("Usage: auto media <image_path> [image2 ...]")
            return
        }
        for path in args.dropFirst() {
            try bridge.addMedia(path: path)
            print("Injected: \(path)")
        }
        let ms = elapsed(start)
        print("Done (\(ms)ms)")

    case "faceid":
        guard args.count >= 2 else {
            print("Usage: auto faceid <enroll|match|fail|status>")
            return
        }
        let ms: Int
        switch args[1] {
        case "enroll":
            try bridge.faceIDEnroll()
            ms = elapsed(start)
            print("Face ID enrollment toggled (\(ms)ms)")
        case "match":
            try bridge.faceIDMatch()
            ms = elapsed(start)
            print("Face ID match sent (\(ms)ms)")
        case "fail":
            try bridge.faceIDFail()
            ms = elapsed(start)
            print("Face ID non-match sent (\(ms)ms)")
        case "status":
            let enrolled = try bridge.faceIDIsEnrolled()
            ms = elapsed(start)
            print("Enrolled: \(enrolled ? "YES" : "NO") (\(ms)ms)")
        default:
            print("Unknown: \(args[1]). Use enroll/match/fail/status")
        }

    case "paste":
        if args.count >= 2 {
            try bridge.setPasteboard(text: args[1])
            print("Set pasteboard: \(args[1])")
        } else {
            let text = try bridge.getPasteboard()
            print(text)
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
            let ms = elapsed(start)
            print("Camera started with '\(args[2])' (\(ms)ms)")
        case "feed":
            guard args.count >= 3 else {
                print("Usage: auto camera feed <image.jpg>")
                return
            }
            try bridge.cameraFeed(imagePath: args[2])
            let ms = elapsed(start)
            print("Camera feed updated: '\(args[2])' (\(ms)ms)")
        case "stop":
            bridge.cameraStop()
            let ms = elapsed(start)
            print("Camera stopped (\(ms)ms)")
        case "status":
            let status = bridge.cameraStatus()
            let ms = elapsed(start)
            if status.active {
                print("ACTIVE — feed: \(status.imagePath ?? "none") (\(ms)ms)")
            } else {
                print("INACTIVE (\(ms)ms)")
            }
        default:
            print("Unknown: \(args[1]). Use start/feed/stop/status")
        }

    case "boot":
        guard args.count >= 2 else {
            print("Usage: auto boot <device_name|udid>")
            return
        }
        try bridge.bootDevice(args[1])
        let ms = elapsed(start)
        print("Booted '\(args[1])' (\(ms)ms)")

    case "shutdown":
        guard args.count >= 2 else {
            print("Usage: auto shutdown <device_name|udid>")
            return
        }
        try bridge.shutdownDevice(args[1])
        let ms = elapsed(start)
        print("Shutdown '\(args[1])' (\(ms)ms)")

    case "install":
        guard args.count >= 2 else {
            print("Usage: auto install <path/to/app.app>")
            return
        }
        try bridge.installApp(path: args[1])
        let ms = elapsed(start)
        print("Installed \(args[1]) (\(ms)ms)")

    case "list":
        let devices = try bridge.listDevices()
        let ms = elapsed(start)
        let booted = devices.filter { $0["state"] as? String == "Booted" }
        let shutdown = devices.filter { $0["state"] as? String == "Shutdown" }

        if !booted.isEmpty {
            print("Booted:")
            for d in booted {
                print("  \(d["name"]!)  \(d["os"]!)  \(d["udid"]!)")
            }
        }
        if !shutdown.isEmpty {
            print("Available:")
            for d in shutdown {
                print("  \(d["name"]!)  \(d["os"]!)")
            }
        }
        print("\n\(devices.count) device(s) (\(ms)ms)")

    case "openurl":
        guard args.count >= 2 else {
            print("Usage: auto openurl <url>")
            return
        }
        try bridge.openURL(args[1])
        let ms = elapsed(start)
        print("Opened URL (\(ms)ms)")

    case "waitFor":
        guard args.count >= 2 else {
            print("Usage: auto waitFor <identifier|label> [timeout_seconds]")
            return
        }
        let target = args[1]
        let timeout = args.count >= 3 ? Double(args[2]) ?? 10.0 : 10.0
        let pollInterval: useconds_t = 500_000 // 500ms
        let maxAttempts = Int(timeout * 2)

        var found = false
        for _ in 0..<maxAttempts {
            let results = try bridge.search(query: target)
            if !results.isEmpty {
                found = true
                break
            }
            usleep(pollInterval)
        }

        let ms = elapsed(start)
        if found {
            print("Found '\(target)' (\(ms)ms)")
        } else {
            print("Timeout: '\(target)' not found after \(timeout)s")
            exit(1)
        }

    case "help", "--help", "-h":
        printUsage()

    default:
        print("Unknown command: \(cmd)")
        printUsage()
    }
}

func elapsed(_ start: CFAbsoluteTime) -> Int {
    Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
}

func printElement(_ el: [String: Any]) {
    let role = el["role"] as? String ?? "?"
    let title = el["title"] as? String ?? ""
    let label = el["label"] as? String ?? ""
    let identifier = el["identifier"] as? String ?? ""
    let frame = el["frame"] as? [String: Any]

    var line = "  \(role)"
    if !title.isEmpty { line += "  \"\(title)\"" }
    if !label.isEmpty && label != title { line += "  label=\"\(label)\"" }
    if !identifier.isEmpty { line += "  id=\(identifier)" }
    if let f = frame {
        line += "  [\(f["x"] ?? 0),\(f["y"] ?? 0) \(f["width"] ?? 0)x\(f["height"] ?? 0)]"
    }
    print(line)
}

func printUsage() {
    print("""
    AutoApp - Control the iOS Simulator directly

    No test runner needed. Just open the Simulator and go.

    Usage: auto <command> [arguments]

    Commands:
      ping                              Check Simulator is running
      tree                              Print accessibility tree
      tree -s "query"                   Search elements
      launch <bundleId>                 Launch app
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
      camera start <image>              Start virtual camera feed
      camera feed <image>               Update camera image
      camera stop                       Stop virtual camera
      camera status                     Check camera status
      terminate <bundleId>              Kill app
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
