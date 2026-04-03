import Foundation

/// Handles platform-agnostic commands via any DeviceBridge.
/// Returns true if the command was handled, false if unrecognized (for platform-specific fallthrough).
public func executeSharedCommand(_ args: [String], bridge: any DeviceBridge) throws -> Bool {
    guard let cmd = args.first else { return false }

    let start = CFAbsoluteTimeGetCurrent()

    switch cmd {

    case "tree":
        if args.count >= 3 && (args[1] == "--search" || args[1] == "-s") {
            let results = try bridge.search(query: args[2])
            let ms = elapsedMs(start)
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
            let ms = elapsedMs(start)
            TreePrinter.printAX(tree)
            print("\n(\(ms)ms)")
        }

    case "tap":
        guard args.count >= 2 else {
            print("Usage: auto tap <label>")
            print("       auto tap a,b,c      (multiple)")
            return true
        }
        let targets = args[1].split(separator: ",").map(String.init)
        for target in targets {
            try bridge.tap(target: target)
            print("Tapped '\(target)' (\(elapsedMs(start))ms)")
        }

    case "longPress":
        guard args.count >= 2 else {
            print("Usage: auto longPress <identifier|title|label> [seconds]")
            return true
        }
        let duration = args.count >= 3 ? Double(args[2]) ?? 1.0 : 1.0
        try bridge.longPress(target: args[1], duration: duration)
        let ms = elapsedMs(start)
        print("Long pressed '\(args[1])' for \(duration)s (\(ms)ms)")

    case "doubleTap":
        guard args.count >= 2 else {
            print("Usage: auto doubleTap <identifier|title|label>")
            return true
        }
        try bridge.doubleTap(target: args[1])
        let ms = elapsedMs(start)
        print("Double tapped '\(args[1])' (\(ms)ms)")

    case "clear":
        guard args.count >= 2 else {
            print("Usage: auto clear <identifier|title|label>")
            return true
        }
        try bridge.clear(target: args[1])
        let ms = elapsedMs(start)
        print("Cleared '\(args[1])' (\(ms)ms)")

    case "type":
        guard args.count >= 2 else {
            print("Usage: auto type <text>")
            return true
        }
        if args.count >= 3 {
            try bridge.tap(target: args[1])
            usleep(200_000)
            try bridge.typeText(args[2])
        } else {
            try bridge.typeText(args[1])
        }
        let ms = elapsedMs(start)
        print("Typed text (\(ms)ms)")

    case "scroll":
        guard args.count >= 3 else {
            print("Usage: auto scroll <identifier|title|label> <up|down|left|right>")
            return true
        }
        try bridge.scroll(target: args[1], direction: args[2])
        let ms = elapsedMs(start)
        print("Scrolled '\(args[1])' \(args[2]) (\(ms)ms)")

    case "swipe":
        guard args.count >= 2 else {
            print("Usage: auto swipe <up|down|left|right>")
            return true
        }
        try bridge.swipe(direction: args[1])
        let ms = elapsedMs(start)
        print("Swiped \(args[1]) (\(ms)ms)")

    case "screenshot":
        let filename = args.count >= 2 ? args[1] : "screenshot.png"
        try bridge.screenshot(path: filename)
        let ms = elapsedMs(start)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: filename)[.size] as? Int) ?? 0
        print("Saved: \(filename) (\(fileSize / 1024)KB, \(ms)ms)")

    case "exists":
        guard args.count >= 2 else {
            print("Usage: auto exists <identifier|title|label>")
            return true
        }
        let results = try bridge.search(query: args[1])
        let ms = elapsedMs(start)
        print(results.isEmpty ? "NO (\(ms)ms)" : "YES (\(ms)ms)")

    case "terminate":
        guard args.count >= 2 else {
            print("Usage: auto terminate <bundleId>")
            return true
        }
        try bridge.terminateApp(bundleId: args[1])
        let ms = elapsedMs(start)
        print("Terminated \(args[1]) (\(ms)ms)")

    case "elementAt":
        guard args.count >= 3,
              let x = Double(args[1]),
              let y = Double(args[2]) else {
            print("Usage: auto elementAt <x> <y>")
            return true
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
            return true
        }
        try bridge.tapAtCoordinate(x: x, y: y)
        let ms = elapsedMs(start)
        print("Tapped at (\(args[1]), \(args[2])) (\(ms)ms)")

    case "media":
        guard args.count >= 2 else {
            print("Usage: auto media <image_path> [image2 ...]")
            return true
        }
        for path in args.dropFirst() {
            try bridge.addMedia(path: path)
            print("Injected: \(path)")
        }
        let ms = elapsedMs(start)
        print("Done (\(ms)ms)")

    case "paste":
        if args.count >= 2 {
            try bridge.setPasteboard(text: args[1])
            print("Set pasteboard: \(args[1])")
        } else {
            let text = try bridge.getPasteboard()
            print(text)
        }

    case "boot":
        guard args.count >= 2 else {
            print("Usage: auto boot <device_name|udid>")
            return true
        }
        try bridge.bootDevice(args[1])
        let ms = elapsedMs(start)
        print("Booted '\(args[1])' (\(ms)ms)")

    case "shutdown":
        guard args.count >= 2 else {
            print("Usage: auto shutdown <device_name|udid>")
            return true
        }
        try bridge.shutdownDevice(args[1])
        let ms = elapsedMs(start)
        print("Shutdown '\(args[1])' (\(ms)ms)")

    case "install":
        guard args.count >= 2 else {
            print("Usage: auto install <path/to/app.app>")
            return true
        }
        try bridge.installApp(path: args[1])
        let ms = elapsedMs(start)
        print("Installed \(args[1]) (\(ms)ms)")

    case "list":
        let devices = try bridge.listDevices()
        let ms = elapsedMs(start)
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
            return true
        }
        try bridge.openURL(args[1])
        let ms = elapsedMs(start)
        print("Opened URL (\(ms)ms)")

    case "waitFor":
        guard args.count >= 2 else {
            print("Usage: auto waitFor <identifier|label> [timeout_seconds]")
            return true
        }
        let target = args[1]
        let timeout = args.count >= 3 ? Double(args[2]) ?? 10.0 : 10.0
        let pollInterval: useconds_t = 500_000
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

        let ms = elapsedMs(start)
        if found {
            print("Found '\(target)' (\(ms)ms)")
        } else {
            print("Timeout: '\(target)' not found after \(timeout)s")
            exit(1)
        }

    case "config":
        if args.count < 2 {
            let config = AutoPilotConfig.readAll()
            if config.isEmpty {
                print("No config set. Use: auto config <key> <value>")
                print("\nAvailable keys:")
                for k in AutoPilotConfig.knownKeys {
                    print("  \(k.key.padding(toLength: 10, withPad: " ", startingAt: 0)) \(k.description)")
                }
            } else {
                print(".autopilot config:")
                for (key, val) in config.sorted(by: { $0.key < $1.key }) {
                    print("  \(key) = \(val)")
                }
            }
            return true
        }
        let key = args[1]
        if args.count < 3 {
            if let val = AutoPilotConfig.get(key) {
                print("\(key) = \(val)")
            } else {
                print("\(key) is not set")
            }
            return true
        }
        let value = args[2...].joined(separator: " ")
        AutoPilotConfig.set(key, value: value)
        print("Set \(key) = \(value)")

    default:
        return false
    }

    return true
}

// MARK: - Shared helpers

public func elapsedMs(_ start: CFAbsoluteTime) -> Int {
    Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
}

public func printElement(_ el: [String: Any]) {
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
