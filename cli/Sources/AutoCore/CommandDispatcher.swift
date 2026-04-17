import Foundation

/// Handles platform-agnostic commands via any DeviceBridge.
/// Returns true if the command was handled, false if unrecognized (for platform-specific fallthrough).
///
/// - Parameters:
///   - args: command-line arguments (first is the verb)
///   - bridge: the primary DeviceBridge (usually HybridBridge on iOS, AgentBridge on Android)
///   - deepBridge: optional deep-only bridge (e.g. XCUIBridge on iOS). When provided,
///                 `tree deep` and `tree full` subcommands will use it. On Android this is nil.
public func executeSharedCommand(_ args: [String], bridge: any DeviceBridge, deepBridge: (any DeviceBridge)? = nil) throws -> Bool {
    guard let rawCmd = args.first else { return false }

    // Strip [role] suffix for switch matching: "tap[button]" → "tap"
    let cmd: String
    if let bracket = rawCmd.firstIndex(of: "[") {
        cmd = String(rawCmd[rawCmd.startIndex..<bracket])
    } else {
        cmd = rawCmd
    }

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
        } else if args.count >= 2 && args[1] == "deep" {
            // Force deep bridge (XCUI on iOS) — slow, sees everything SwiftUI exposes
            guard let deep = deepBridge else {
                print("tree deep: no deep bridge available on this platform (iOS only)")
                return true
            }
            let tree = try deep.tree()
            let ms = elapsedMs(start)
            TreePrinter.printAX(tree)
            print("\n(\(ms)ms — deep)")
        } else if args.count >= 2 && args[1] == "full" {
            // Fast + deep merged — deep adds what fast missed (NavBar buttons, etc.)
            let fastTree = (try? bridge.tree()) ?? []
            let deepTree: [[String: Any]]
            if let deep = deepBridge {
                deepTree = (try? deep.tree()) ?? []
            } else {
                deepTree = []
            }
            let ms = elapsedMs(start)
            print("=== fast (AX macOS) ===")
            TreePrinter.printAX(fastTree)
            if !deepTree.isEmpty {
                print("\n=== deep (XCUI runner) ===")
                TreePrinter.printAX(deepTree)
            } else if deepBridge == nil {
                print("\n(no deep bridge available on this platform)")
            }
            print("\n(\(ms)ms — full)")
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
        // Parse type[N] for "Nth text input" syntax. The bracket part is in
        // rawCmd because the switch above stripped it. Numeric -> index of
        // text input in tree (1-based, only AXTextField/AXSecureTextField/EditText).
        var nthInputIndex: Int? = nil
        if let bracket = rawCmd.firstIndex(of: "["),
           let end = rawCmd.lastIndex(of: "]"),
           bracket < end {
            let inner = String(rawCmd[rawCmd.index(after: bracket)..<end])
            nthInputIndex = Int(inner)
        }

        guard args.count >= 2 else {
            print("Usage: auto type <text>")
            print("       auto type <target> <text>      (tap target, then type)")
            print("       auto type[N] <text>            (tap Nth text input, then type)")
            return true
        }

        if let n = nthInputIndex {
            // type[N] "text" — find Nth text input in tree, tap its center, then type.
            // Filters by role (AXTextField/AXSecureTextField/EditText) so it never
            // resolves to a sibling AXStaticText with the same label.
            try tapNthTextInput(bridge: bridge, index: n)
            usleep(200_000)
            try bridge.typeText(args[1])
        } else if args.count >= 3 {
            // type "target" "text" — smart resolution: prefer the text input whose
            // label/value/identifier matches the target over a sibling AXStaticText
            // with the same label. This is what makes
            //   type "Email o DNI" "user@example.com"
            // work even when the form has both an AXStaticText (visible label above
            // the field) and an AXTextField (placeholder text inside the field) with
            // the same string.
            if try !tapTextInputByLabel(bridge: bridge, label: args[1]) {
                // Fallback to plain bridge.tap when no text input matches the label
                // (the target may be a button, link, etc.)
                try bridge.tap(target: args[1])
            }
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

        // Support label[N] syntax: waitFor "Cerrar sesion[2]" waits for 2+ matches
        let (searchLabel, requiredCount) = TargetResolverShared.parse(target)
        let minMatches = requiredCount ?? 1

        var found = false
        for _ in 0..<maxAttempts {
            // Catch errors (e.g., "No active window" during app launch) and retry
            if let results = try? bridge.search(query: searchLabel), results.count >= minMatches {
                found = true
                break
            }
            usleep(pollInterval)
        }

        let ms = elapsedMs(start)
        if found {
            print("Found '\(target)' (\(ms)ms)")
        } else {
            throw BridgeError.timeout("Timeout: '\(target)' not found after \(timeout)s")
        }

    case "waitUntilGone":
        guard args.count >= 2 else {
            print("Usage: auto waitUntilGone <identifier|label> [timeout_seconds]")
            return true
        }
        let target = args[1]
        let timeout = args.count >= 3 ? Double(args[2]) ?? 10.0 : 10.0
        let pollInterval: useconds_t = 500_000
        let maxAttempts = Int(timeout * 2)

        // Support label[N] syntax: waitUntilGone "Item[2]" waits until fewer than 2 matches
        let (searchLabel, requiredCount) = TargetResolverShared.parse(target)
        let minMatches = requiredCount ?? 1

        var gone = false
        for _ in 0..<maxAttempts {
            let results = (try? bridge.search(query: searchLabel)) ?? []
            if results.count < minMatches {
                gone = true
                break
            }
            usleep(pollInterval)
        }

        let wms = elapsedMs(start)
        if gone {
            print("Gone '\(target)' (\(wms)ms)")
        } else {
            throw BridgeError.timeout("Timeout: '\(target)' still present after \(timeout)s")
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

    case "wait", "sleep":
        let seconds = args.count >= 2 ? Double(args[1]) ?? 1.0 : 1.0
        usleep(UInt32(seconds * 1_000_000))
        let ms = elapsedMs(start)
        print("Waited \(seconds)s (\(ms)ms)")

    case "drag":
        guard args.count >= 3 else {
            print("Usage: auto drag <from> <to> [duration]")
            print("       auto drag \"Element A\" \"Element B\" 1.0")
            print("       auto drag 100,200 300,400")
            return true
        }
        let duration = args.count >= 4 ? Double(args[3]) ?? 0.5 : 0.5
        let fromArg = args[1]
        let toArg = args[2]
        // Check if arguments are coordinates (format: "x,y")
        let fromParts = fromArg.split(separator: ",")
        let toParts = toArg.split(separator: ",")
        if fromParts.count == 2, let fx = Double(fromParts[0]), let fy = Double(fromParts[1]),
           toParts.count == 2, let tx = Double(toParts[0]), let ty = Double(toParts[1]) {
            try bridge.dragCoordinates(x1: fx, y1: fy, x2: tx, y2: ty, duration: duration)
            let ms = elapsedMs(start)
            print("Dragged (\(fx),\(fy)) → (\(tx),\(ty)) (\(ms)ms)")
        } else {
            try bridge.drag(from: fromArg, to: toArg, duration: duration)
            let ms = elapsedMs(start)
            print("Dragged '\(fromArg)' → '\(toArg)' (\(ms)ms)")
        }

    case "biometric", "faceid":
        guard args.count >= 2 else {
            print("Usage: auto biometric <enroll|unenroll|match|fail|status>")
            return true
        }
        let ms: Int
        switch args[1] {
        case "enroll":
            try bridge.biometricEnroll()
            ms = elapsedMs(start)
            print("Biometric enrolled (\(ms)ms)")
        case "unenroll":
            try bridge.biometricUnenroll()
            ms = elapsedMs(start)
            print("Biometric unenrolled (\(ms)ms)")
        case "match":
            try bridge.biometricMatch()
            ms = elapsedMs(start)
            print("Biometric match sent (\(ms)ms)")
        case "fail":
            try bridge.biometricFail()
            ms = elapsedMs(start)
            print("Biometric non-match sent (\(ms)ms)")
        case "status":
            let enrolled = try bridge.biometricIsEnrolled()
            ms = elapsedMs(start)
            print("Enrolled: \(enrolled ? "YES" : "NO") (\(ms)ms)")
        default:
            print("Unknown: \(args[1]). Use enroll/unenroll/match/fail/status")
        }

    case "permission":
        guard args.count >= 4 else {
            print("Usage: auto permission <grant|revoke|reset> <service> <bundleId>")
            print("       Services: camera, microphone, photos, contacts, calendars,")
            print("                 reminders, location, bluetooth, health, homekit,")
            print("                 notifications, all")
            return true
        }
        let action = args[1]
        let service = args[2]
        let bundleId = args[3]
        try bridge.setPermission(action: action, service: service, bundleId: bundleId)
        let ms = elapsedMs(start)
        print("Permission \(action) \(service) → \(bundleId) (\(ms)ms)")

    case "logs":
        let bundleId: String? = (args.count >= 2 && !args[1].hasPrefix("--")) ? args[1] : nil
        var lines = 50
        if let idx = args.firstIndex(of: "--lines"), idx + 1 < args.count {
            lines = Int(args[idx + 1]) ?? 50
        }
        let isSystem = args.contains("--system")
        let output = try bridge.getLogs(bundleId: isSystem ? nil : bundleId, lines: lines)
        print(output)

    case "rotate":
        guard args.count >= 2 else {
            print("Usage: auto rotate <left|right|portrait|landscape>")
            return true
        }
        try bridge.rotate(direction: args[1])
        let ms = elapsedMs(start)
        print("Rotated \(args[1]) (\(ms)ms)")

    // MARK: - Keyboard

    case "pressKey":
        guard args.count >= 2 else {
            print("Usage: auto pressKey <home|back|enter|delete|volumeUp|volumeDown|power|tab|escape>")
            return true
        }
        try bridge.pressKey(key: args[1])
        let ms = elapsedMs(start)
        print("Pressed key '\(args[1])' (\(ms)ms)")

    case "hideKeyboard":
        try bridge.hideKeyboard()
        let ms = elapsedMs(start)
        print("Keyboard dismissed (\(ms)ms)")

    case "eraseText":
        let count = args.count >= 2 ? Int(args[1]) ?? 1 : 1
        try bridge.eraseText(count: count)
        let ms = elapsedMs(start)
        print("Erased \(count) character(s) (\(ms)ms)")

    // MARK: - Text Extraction

    case "copyTextFrom":
        guard args.count >= 2 else {
            print("Usage: auto copyTextFrom <element>")
            return true
        }
        let text = try bridge.copyTextFrom(target: args[1])
        let ms = elapsedMs(start)
        print("\(text)")
        if isatty(1) != 0 {
            fputs("(\(ms)ms)\n", stderr)
        }

    // MARK: - App Data

    case "clearState":
        guard args.count >= 2 else {
            print("Usage: auto clearState <bundleId>")
            return true
        }
        try bridge.clearState(bundleId: args[1])
        let ms = elapsedMs(start)
        print("Cleared state for \(args[1]) (\(ms)ms)")

    case "uninstall":
        guard args.count >= 2 else {
            print("Usage: auto uninstall <bundleId>")
            return true
        }
        try bridge.uninstallApp(bundleId: args[1])
        let ms = elapsedMs(start)
        print("Uninstalled \(args[1]) (\(ms)ms)")

    case "keychain":
        // Subcommand-style: `keychain reset`. Leaves room for future
        // `keychain add-cert` / `add-root-cert` mirroring simctl, without
        // crowding the top-level command list today.
        guard args.count >= 2 else {
            print("Usage: auto keychain reset")
            return true
        }
        switch args[1] {
        case "reset":
            try bridge.resetKeychain()
            let ms = elapsedMs(start)
            print("Keychain reset (\(ms)ms)")
        default:
            print("Usage: auto keychain reset")
            print("Unknown subcommand: '\(args[1])'")
        }

    // MARK: - Scroll Search
    // `scrollUntilVisible` is an alias of `scrollTo` (emitted by recorder).

    case "scrollTo", "scrollUntilVisible":
        guard args.count >= 2 else {
            print("Usage: auto \(args[0]) <element> [direction] [maxAttempts]")
            return true
        }
        let direction = args.count >= 3 ? args[2] : "down"
        let maxAttempts = args.count >= 4 ? Int(args[3]) ?? 20 : 20
        try bridge.scrollTo(target: args[1], direction: direction, maxAttempts: maxAttempts)
        let ms = elapsedMs(start)
        print("Scrolled '\(args[1])' into view (\(ms)ms)")

    // MARK: - Screen Recording

    case "startRecording":
        try bridge.startRecording()
        let ms = elapsedMs(start)
        print("Recording started (\(ms)ms)")

    case "stopRecording":
        guard args.count >= 2 else {
            print("Usage: auto stopRecording <output.mp4>")
            return true
        }
        try bridge.stopRecording(outputPath: args[1])
        let ms = elapsedMs(start)
        print("Recording saved to \(args[1]) (\(ms)ms)")

    // MARK: - Device Environment

    case "setLocation":
        guard args.count >= 3 else {
            print("Usage: auto setLocation <latitude> <longitude>")
            return true
        }
        guard let lat = Double(args[1]), let lon = Double(args[2]) else {
            print("Error: latitude and longitude must be numbers")
            return true
        }
        try bridge.setLocation(latitude: lat, longitude: lon)
        let ms = elapsedMs(start)
        print("Location set to \(lat), \(lon) (\(ms)ms)")

    case "setAppearance":
        guard args.count >= 2 else {
            print("Usage: auto setAppearance <dark|light>")
            return true
        }
        try bridge.setAppearance(mode: args[1])
        let ms = elapsedMs(start)
        print("Appearance set to \(args[1]) (\(ms)ms)")

    case "lockDevice":
        try bridge.lockDevice()
        let ms = elapsedMs(start)
        print("Device locked (\(ms)ms)")

    case "unlockDevice":
        try bridge.unlockDevice()
        let ms = elapsedMs(start)
        print("Device unlocked (\(ms)ms)")

    // MARK: - File Transfer

    case "pushFile":
        guard args.count >= 3 else {
            print("Usage: auto pushFile <localPath> <remotePath>")
            return true
        }
        try bridge.pushFile(localPath: args[1], remotePath: args[2])
        let ms = elapsedMs(start)
        print("Pushed \(args[1]) → \(args[2]) (\(ms)ms)")

    case "pullFile":
        guard args.count >= 3 else {
            print("Usage: auto pullFile <remotePath> <localPath>")
            return true
        }
        try bridge.pullFile(remotePath: args[1], localPath: args[2])
        let ms = elapsedMs(start)
        print("Pulled \(args[1]) → \(args[2]) (\(ms)ms)")

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

// MARK: - type[N] support

/// Recursively collects every text-input element from the tree, in document order.
/// Used by `type[N]` to resolve the Nth text input regardless of label/sibling noise.
/// iOS roles: AXTextField, AXSecureTextField. Android roles: anything ending in EditText.
private func collectTextInputs(_ elements: [[String: Any]], into result: inout [[String: Any]]) {
    for el in elements {
        if let role = el["role"] as? String {
            let isTextInput = role == "AXTextField"
                || role == "AXSecureTextField"
                || role == "EditText"
                || role.hasSuffix(".EditText")
                || role.hasSuffix("EditText")
            if isTextInput {
                result.append(el)
            }
        }
        if let children = el["children"] as? [[String: Any]] {
            collectTextInputs(children, into: &result)
        }
    }
}

/// Finds the Nth text input in the live tree (1-indexed) and taps the center of its frame.
/// Throws BridgeError if N is out of range or the element has no usable frame.
func tapNthTextInput(bridge: any DeviceBridge, index: Int) throws {
    let tree = try bridge.tree()
    var inputs: [[String: Any]] = []
    collectTextInputs(tree, into: &inputs)

    guard !inputs.isEmpty else {
        throw BridgeError.elementNotFound("type[\(index)]: no text inputs found in current tree")
    }
    guard index >= 1 && index <= inputs.count else {
        throw BridgeError.elementNotFound("type[\(index)]: only \(inputs.count) text input(s) in current tree")
    }

    try tapElementCenter(inputs[index - 1], hint: "text input [\(index)]", bridge: bridge)
}

/// Finds the first text input whose label/value/title/identifier matches `label`
/// and taps the center of its frame. Returns true on success, false if no text
/// input matches (caller can fallback to a plain `bridge.tap`).
///
/// This is the smart resolver used by `auto type <target> <text>` (3 args). It
/// prefers a text input over a sibling AXStaticText with the same label, which
/// is what allows `type "Email o DNI" "user@example.com"` to work even when the
/// form has both a label-only StaticText and a TextField with the same string.
func tapTextInputByLabel(bridge: any DeviceBridge, label: String) throws -> Bool {
    let tree = try bridge.tree()
    var inputs: [[String: Any]] = []
    collectTextInputs(tree, into: &inputs)
    if inputs.isEmpty { return false }

    let needle = label.lowercased()
    for field in inputs {
        let candidates: [String] = [
            (field["label"] as? String) ?? "",
            (field["title"] as? String) ?? "",
            (field["value"] as? String) ?? "",
            (field["identifier"] as? String) ?? "",
            (field["placeholder"] as? String) ?? "",
        ]
        for candidate in candidates where !candidate.isEmpty {
            if candidate.lowercased() == needle || candidate.lowercased().contains(needle) {
                try tapElementCenter(field, hint: "text input '\(label)'", bridge: bridge)
                return true
            }
        }
    }
    return false
}

/// Tap the center of `element`'s frame via `bridge`. Throws if no frame.
private func tapElementCenter(_ element: [String: Any], hint: String, bridge: any DeviceBridge) throws {
    guard let frame = element["frame"] as? [String: Any],
          let fx = frame["x"] as? Int,
          let fy = frame["y"] as? Int,
          let fw = frame["width"] as? Int,
          let fh = frame["height"] as? Int else {
        throw BridgeError.noFrame(hint)
    }
    let cx = Double(fx + fw / 2)
    let cy = Double(fy + fh / 2)
    try bridge.tapAtCoordinate(x: cx, y: cy)
}
