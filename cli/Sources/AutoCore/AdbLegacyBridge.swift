import Foundation

/// Legacy bridge: controls Android via adb shell commands (fork per command).
/// Kept for benchmarks and as fallback. Use AgentBridge for production.
public final class AdbLegacyBridge: DeviceBridge {

    private var selectedDeviceId: String?
    private var cachedAdbPath: String?
    private var recordingProcess: Process?

    public init(deviceId: String? = nil) {
        self.selectedDeviceId = deviceId
    }

    // MARK: - ADB Helpers

    private func adbPath() throws -> String {
        if let cached = cachedAdbPath { return cached }

        // Check ANDROID_HOME
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            let path = "\(home)/platform-tools/adb"
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedAdbPath = path
                return path
            }
        }

        // Check ANDROID_SDK_ROOT (legacy)
        if let root = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            let path = "\(root)/platform-tools/adb"
            if FileManager.default.isExecutableFile(atPath: path) {
                cachedAdbPath = path
                return path
            }
        }

        // Try which
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["adb"]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        try? which.run()
        which.waitUntilExit()

        if which.terminationStatus == 0 {
            let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !path.isEmpty {
                cachedAdbPath = path
                return path
            }
        }

        throw BridgeError.adbNotFound
    }

    /// Public accessor for other bridges that need adb commands.
    @discardableResult
    public func runAdbPublic(_ arguments: [String]) throws -> String {
        return try runAdb(arguments)
    }

    @discardableResult
    private func runAdb(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try adbPath())

        var args = arguments
        if let deviceId = selectedDeviceId {
            args = ["-s", deviceId] + args
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let output = String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            let err = String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BridgeError.adbFailed(err.isEmpty ? "exit \(process.terminationStatus)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return output
    }

    private func dumpUITree() throws -> [[String: Any]] {
        let xml = try runAdb(["exec-out", "uiautomator", "dump", "/dev/tty"])
        return try UIAutomatorParser.parse(xml)
    }

    private func searchRecursive(
        elements: [[String: Any]],
        query: String,
        results: inout [[String: Any]]
    ) {
        let q = query.lowercased()
        for el in elements {
            let title = (el["title"] as? String ?? "").lowercased()
            let label = (el["label"] as? String ?? "").lowercased()
            let identifier = (el["identifier"] as? String ?? "").lowercased()
            let value = (el["value"] as? String ?? "").lowercased()
            let role = (el["role"] as? String ?? "").lowercased()

            if title.contains(q) || label.contains(q) || identifier.contains(q) ||
               value.contains(q) || role.contains(q) {
                results.append(el)
            }

            if let children = el["children"] as? [[String: Any]] {
                searchRecursive(elements: children, query: query, results: &results)
            }
        }
    }

    private func findElement(in tree: [[String: Any]], matching query: String) -> [String: Any]? {
        let q = query.lowercased()
        for el in tree {
            let title = (el["title"] as? String ?? "").lowercased()
            let label = (el["label"] as? String ?? "").lowercased()
            let identifier = (el["identifier"] as? String ?? "").lowercased()

            // Exact match first
            if title == q || label == q || identifier == q {
                return el
            }

            if let children = el["children"] as? [[String: Any]] {
                if let found = findElement(in: children, matching: query) {
                    return found
                }
            }
        }

        // Second pass: contains match
        return findElementContains(in: tree, query: q)
    }

    private func findElementContains(in tree: [[String: Any]], query: String) -> [String: Any]? {
        for el in tree {
            let title = (el["title"] as? String ?? "").lowercased()
            let label = (el["label"] as? String ?? "").lowercased()
            let identifier = (el["identifier"] as? String ?? "").lowercased()

            if title.contains(query) || label.contains(query) || identifier.contains(query) {
                return el
            }

            if let children = el["children"] as? [[String: Any]] {
                if let found = findElementContains(in: children, query: query) {
                    return found
                }
            }
        }
        return nil
    }

    private func centerOf(_ element: [String: Any]) throws -> (x: Int, y: Int) {
        guard let frame = element["frame"] as? [String: Int],
              let x = frame["x"], let y = frame["y"],
              let w = frame["width"], let h = frame["height"] else {
            let title = element["title"] as? String ?? element["identifier"] as? String ?? "unknown"
            throw BridgeError.noFrame(title)
        }
        return (x: x + w / 2, y: y + h / 2)
    }

    private func getScreenSize() throws -> (width: Int, height: Int) {
        let output = try runAdb(["shell", "wm", "size"])
        // "Physical size: 1080x1920"
        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ").last?
            .components(separatedBy: "x") ?? []

        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else {
            throw BridgeError.adbFailed("Could not parse screen size from: \(output)")
        }
        return (width: w, height: h)
    }

    private func escapeForAdbInput(_ text: String) -> String {
        var escaped = ""
        for char in text {
            switch char {
            case " ": escaped += "%s"
            case "&", "(", ")", "<", ">", "|", ";", "*", "~", "\"", "'", "`", "{", "}", "\\", "$", "?", "!":
                escaped += "\\\(char)"
            default:
                escaped += String(char)
            }
        }
        return escaped
    }

    private func findElementDeepest(in tree: [[String: Any]], containing point: (x: Double, y: Double)) -> [String: Any]? {
        var best: [String: Any]?
        var bestArea = Int.max

        func recurse(_ elements: [[String: Any]]) {
            for el in elements {
                if let frame = el["frame"] as? [String: Int],
                   let fx = frame["x"], let fy = frame["y"],
                   let fw = frame["width"], let fh = frame["height"] {
                    let x1 = Double(fx), y1 = Double(fy)
                    let x2 = x1 + Double(fw), y2 = y1 + Double(fh)

                    if point.x >= x1 && point.x <= x2 && point.y >= y1 && point.y <= y2 {
                        let area = fw * fh
                        if area < bestArea {
                            bestArea = area
                            best = el
                        }
                    }
                }
                if let children = el["children"] as? [[String: Any]] {
                    recurse(children)
                }
            }
        }

        recurse(tree)
        return best
    }

    // MARK: - DeviceBridge: Accessibility Tree

    public func tree() throws -> [[String: Any]] {
        return try dumpUITree()
    }

    public func search(query: String) throws -> [[String: Any]] {
        let tree = try dumpUITree()
        var results: [[String: Any]] = []
        searchRecursive(elements: tree, query: query, results: &results)
        return results
    }

    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        let tree = try dumpUITree()
        return findElementDeepest(in: tree, containing: (x: x, y: y))
    }

    // MARK: - DeviceBridge: Actions

    public func tap(target: String) throws {
        let tree = try dumpUITree()
        guard let element = findElement(in: tree, matching: target) else {
            throw BridgeError.elementNotFound(target)
        }
        let center = try centerOf(element)
        try runAdb(["shell", "input", "tap", "\(center.x)", "\(center.y)"])
    }

    public func longPress(target: String, duration: Double) throws {
        let tree = try dumpUITree()
        guard let element = findElement(in: tree, matching: target) else {
            throw BridgeError.elementNotFound(target)
        }
        let center = try centerOf(element)
        let ms = Int(duration * 1000)
        // Swipe to same point = long press
        try runAdb(["shell", "input", "swipe", "\(center.x)", "\(center.y)", "\(center.x)", "\(center.y)", "\(ms)"])
    }

    public func doubleTap(target: String) throws {
        let tree = try dumpUITree()
        guard let element = findElement(in: tree, matching: target) else {
            throw BridgeError.elementNotFound(target)
        }
        let center = try centerOf(element)
        try runAdb(["shell", "input", "tap", "\(center.x)", "\(center.y)"])
        usleep(100_000)
        try runAdb(["shell", "input", "tap", "\(center.x)", "\(center.y)"])
    }

    public func clear(target: String) throws {
        // Tap to focus
        try tap(target: target)
        usleep(200_000)

        // Get text length from fresh tree
        let tree = try dumpUITree()
        if let element = findElement(in: tree, matching: target) {
            let text = element["title"] as? String ?? ""
            if !text.isEmpty {
                // Move to end, then delete each character
                try runAdb(["shell", "input", "keyevent", "123"]) // KEYCODE_MOVE_END
                for _ in 0..<text.count {
                    try runAdb(["shell", "input", "keyevent", "67"]) // KEYCODE_DEL
                }
                return
            }
        }

        // Fallback: select all + delete
        try runAdb(["shell", "input", "keyevent", "123"]) // MOVE_END
        for _ in 0..<100 {
            try runAdb(["shell", "input", "keyevent", "67"]) // DEL
        }
    }

    public func typeText(_ text: String) throws {
        let escaped = escapeForAdbInput(text)
        try runAdb(["shell", "input", "text", escaped])
    }

    public func scroll(target: String, direction: String) throws {
        let tree = try dumpUITree()
        guard let element = findElement(in: tree, matching: target) else {
            throw BridgeError.elementNotFound(target)
        }
        let center = try centerOf(element)
        guard let frame = element["frame"] as? [String: Int],
              let h = frame["height"], let w = frame["width"] else {
            throw BridgeError.noFrame(target)
        }

        let distance: Int
        let (x1, y1, x2, y2): (Int, Int, Int, Int)

        switch direction.lowercased() {
        case "up":
            distance = min(h * 40 / 100, 200)
            (x1, y1, x2, y2) = (center.x, center.y, center.x, center.y - distance)
        case "down":
            distance = min(h * 40 / 100, 200)
            (x1, y1, x2, y2) = (center.x, center.y, center.x, center.y + distance)
        case "left":
            distance = min(w * 40 / 100, 200)
            (x1, y1, x2, y2) = (center.x, center.y, center.x - distance, center.y)
        case "right":
            distance = min(w * 40 / 100, 200)
            (x1, y1, x2, y2) = (center.x, center.y, center.x + distance, center.y)
        default:
            throw BridgeError.invalidDirection(direction)
        }

        try runAdb(["shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "300"])
    }

    public func swipe(direction: String) throws {
        let screen = try getScreenSize()
        let cx = screen.width / 2
        let cy = screen.height / 2
        let dx = screen.width * 40 / 100
        let dy = screen.height * 40 / 100

        let (x1, y1, x2, y2): (Int, Int, Int, Int)

        switch direction.lowercased() {
        case "up":    (x1, y1, x2, y2) = (cx, cy + dy / 2, cx, cy - dy / 2)
        case "down":  (x1, y1, x2, y2) = (cx, cy - dy / 2, cx, cy + dy / 2)
        case "left":  (x1, y1, x2, y2) = (cx + dx / 2, cy, cx - dx / 2, cy)
        case "right": (x1, y1, x2, y2) = (cx - dx / 2, cy, cx + dx / 2, cy)
        default:
            throw BridgeError.invalidDirection(direction)
        }

        try runAdb(["shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "300"])
    }

    public func tapAtCoordinate(x: Double, y: Double) throws {
        try runAdb(["shell", "input", "tap", "\(Int(x))", "\(Int(y))"])
    }

    // MARK: - DeviceBridge: App Lifecycle

    public func launchApp(bundleId: String, envVars: [String: String]) throws {
        if envVars.isEmpty {
            // Try monkey first (resolves correct launcher activity), fall back to am start
            do {
                try runAdb(["shell", "monkey", "-p", bundleId,
                            "-c", "android.intent.category.LAUNCHER", "1"])
            } catch {
                // monkey fails on some emulators — fall back to am start
                // First try resolving launcher activity via pm dump
                let launcherActivity = resolveLauncherActivity(bundleId)
                if let activity = launcherActivity {
                    try runAdb(["shell", "am", "start", "-n", "\(bundleId)/\(activity)"])
                } else {
                    try runAdb(["shell", "am", "start",
                                "-a", "android.intent.action.MAIN",
                                "-c", "android.intent.category.LAUNCHER",
                                "-p", bundleId])
                }
            }
        } else {
            var cmdArgs = ["shell", "am", "start",
                           "-a", "android.intent.action.MAIN",
                           "-c", "android.intent.category.LAUNCHER",
                           "-p", bundleId]
            for (key, value) in envVars.sorted(by: { $0.key < $1.key }) {
                cmdArgs.append(contentsOf: ["--es", "AUTOPILOT_\(key)", value])
            }
            try runAdb(cmdArgs)
        }
    }

    /// Resolve the launcher activity for a package via `cmd package resolve-activity`.
    private func resolveLauncherActivity(_ bundleId: String) -> String? {
        do {
            let output = try runAdb(["shell", "cmd", "package", "resolve-activity",
                                     "--brief", "-c", "android.intent.category.LAUNCHER",
                                     "-a", "android.intent.action.MAIN", bundleId])
            // Output format: "priority=0 preferredOrder=0 match=0x108000 specificIndex=-1 isDefault=true\ncom.pkg/.Activity"
            let lines = output.split(separator: "\n")
            if let last = lines.last, last.contains("/") {
                let component = String(last).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = component.split(separator: "/")
                if parts.count == 2 {
                    return String(parts[1])
                }
            }
        } catch {}
        return nil
    }

    public func terminateApp(bundleId: String) throws {
        try runAdb(["shell", "am", "force-stop", bundleId])
    }

    // MARK: - DeviceBridge: Device Management

    public func listDevices() throws -> [[String: Any]] {
        let output = try runAdb(["devices", "-l"])
        var devices: [[String: Any]] = []

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty,
                  !trimmed.hasPrefix("List of"),
                  !trimmed.hasPrefix("*") else { continue }

            let parts = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }

            let deviceId = parts[0]
            let status = parts[1]

            // Parse key:value pairs
            var info: [String: String] = [:]
            for part in parts.dropFirst(2) {
                let kv = part.components(separatedBy: ":")
                if kv.count == 2 { info[kv[0]] = kv[1] }
            }

            devices.append([
                "name": info["model"] ?? deviceId,
                "udid": deviceId,
                "state": status == "device" ? "Booted" : status,
                "os": "Android"
            ])
        }

        return devices
    }

    public func bootDevice(_ nameOrUdid: String) throws {
        // For ADB, "boot" means select this device
        selectedDeviceId = nameOrUdid
    }

    public func shutdownDevice(_ nameOrUdid: String) throws {
        try runAdb(["shell", "reboot", "-p"])
    }

    public func installApp(path: String) throws {
        try runAdb(["install", "-r", path])
    }

    public func getBootedDeviceId() throws -> String {
        if let selected = selectedDeviceId { return selected }

        let devices = try listDevices()
        guard let first = devices.first(where: { $0["state"] as? String == "Booted" }),
              let udid = first["udid"] as? String else {
            throw BridgeError.noBootedDevice
        }

        selectedDeviceId = udid
        return udid
    }

    // MARK: - DeviceBridge: Media & IO

    public func screenshot(path: String) throws {
        let remotePath = "/sdcard/autopilot_screenshot.png"
        try runAdb(["shell", "screencap", "-p", remotePath])
        try runAdb(["pull", remotePath, path])
        try runAdb(["shell", "rm", remotePath])
    }

    public func addMedia(path: String) throws {
        let filename = (path as NSString).lastPathComponent
        try runAdb(["push", path, "/sdcard/DCIM/\(filename)"])
        try runAdb(["shell", "am", "broadcast",
                     "-a", "android.intent.action.MEDIA_SCANNER_SCAN_FILE",
                     "-d", "file:///sdcard/DCIM/\(filename)"])
    }

    public func openURL(_ url: String) throws {
        try runAdb(["shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", url])
    }

    public func setPasteboard(text: String) throws {
        // No direct ADB clipboard API — type text as workaround
        try typeText(text)
    }

    public func getPasteboard() throws -> String {
        throw BridgeError.adbFailed("Clipboard read not supported via ADB")
    }

    // MARK: - DeviceBridge: Biometric (via adb emu)

    /// Enrolla fingerprint en el emulador automáticamente.
    /// Configura PIN lockscreen + navega Settings + simula toques del sensor.
    public func biometricEnroll() throws {
        // Skip if already enrolled
        if try biometricIsEnrolled() { return }

        // 1. Set lock screen PIN (required for fingerprint)
        // Try without old PIN first, then with old PIN if already set
        let pinResult = try? runAdb(["shell", "locksettings", "set-pin", "1234"])
        if pinResult == nil {
            try? runAdb(["shell", "locksettings", "set-pin", "--old", "1234", "1234"])
        }

        // 2. Open fingerprint enrollment
        try runAdb(["shell", "am", "start", "-a", "android.settings.BIOMETRIC_ENROLL"])
        usleep(2_000_000) // Wait for Settings to open

        // 3. Enter lockscreen PIN
        try runAdb(["shell", "input", "text", "1234"])
        try runAdb(["shell", "input", "keyevent", "66"]) // ENTER
        usleep(2_000_000) // Wait for enrollment screen

        // 4. Scroll down and tap MORE then I AGREE
        try runAdb(["shell", "input", "swipe", "640", "2000", "640", "1000", "300"])
        usleep(1_000_000)
        // Try tapping MORE (may or may not appear)
        try? runAdb(["shell", "input", "tap", "1088", "2676"]) // approximate MORE button
        usleep(1_000_000)
        // Try tapping I AGREE
        try? runAdb(["shell", "input", "tap", "1088", "2676"]) // approximate I AGREE button
        usleep(2_000_000)

        // 5. Simulate fingerprint touches (15 times)
        for _ in 0..<15 {
            try runAdb(["-e", "emu", "finger", "touch", "1"])
            usleep(500_000)
        }
        usleep(2_000_000)

        // 6. Tap DONE
        try? runAdb(["shell", "input", "tap", "1088", "2676"]) // approximate DONE button
        usleep(1_000_000)

        // 7. Go back to home
        try runAdb(["shell", "input", "keyevent", "3"]) // HOME
    }

    /// Des-enrolla fingerprint removiendo el lock screen.
    public func biometricUnenroll() throws {
        try runAdb(["shell", "locksettings", "clear", "--old", "1234"])
    }

    public func biometricMatch() throws {
        try runAdb(["-e", "emu", "finger", "touch", "1"])
    }

    public func biometricFail() throws {
        try runAdb(["-e", "emu", "finger", "touch", "0"])
    }

    public func biometricIsEnrolled() throws -> Bool {
        // locksettings get-disabled returns "true" if no lock credential
        // If there IS a lock credential (PIN), fingerprint is likely enrolled
        // (because we set the PIN as part of biometric enrollment)
        let output = try runAdb(["shell", "locksettings", "get-disabled"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "false"
    }

    // MARK: - Logs

    public func getLogs(bundleId: String?, lines: Int) throws -> String {
        let output = try runAdb(["logcat", "-d", "-t", "\(lines)"])
        guard let bundleId = bundleId else { return output }
        let filtered = output.split(separator: "\n")
            .filter { $0.contains(bundleId) }
            .joined(separator: "\n")
        return filtered.isEmpty ? output : filtered
    }

    // MARK: - Permissions

    public func setPermission(action: String, service: String, bundleId: String) throws {
        let adbAction: String
        switch action {
        case "grant":   adbAction = "grant"
        case "revoke":  adbAction = "revoke"
        case "reset":
            throw BridgeError.adbFailed("permission reset not supported on Android. Use 'revoke' or reset via Settings.")
        default:
            throw BridgeError.adbFailed("Invalid action: \(action)")
        }
        let androidPermission: String
        switch service {
        case "camera":        androidPermission = "android.permission.CAMERA"
        case "microphone":    androidPermission = "android.permission.RECORD_AUDIO"
        case "photos":        androidPermission = "android.permission.READ_MEDIA_IMAGES"
        case "contacts":      androidPermission = "android.permission.READ_CONTACTS"
        case "calendars":     androidPermission = "android.permission.READ_CALENDAR"
        case "location":      androidPermission = "android.permission.ACCESS_FINE_LOCATION"
        case "notifications": androidPermission = "android.permission.POST_NOTIFICATIONS"
        default:
            throw BridgeError.adbFailed("Service '\(service)' not mapped for Android. Use the full Android permission string.")
        }
        try runAdb(["shell", "pm", adbAction, bundleId, androidPermission])
    }

    // MARK: - Device Orientation

    public func rotate(direction: String) throws {
        try runAdb(["shell", "settings", "put", "system", "accelerometer_rotation", "0"])
        let rotation: String
        switch direction {
        case "portrait":           rotation = "0"
        case "landscape", "right": rotation = "1"
        case "left":               rotation = "3"
        default:
            throw BridgeError.adbFailed("Invalid direction '\(direction)'. Use: left, right, portrait, landscape")
        }
        try runAdb(["shell", "settings", "put", "system", "user_rotation", rotation])
    }

    // MARK: - Drag

    public func drag(from: String, to: String, duration: Double) throws {
        let tree = try dumpUITree()
        guard let fromEl = findElement(in: tree, matching: from) else {
            throw BridgeError.elementNotFound(from)
        }
        guard let toEl = findElement(in: tree, matching: to) else {
            throw BridgeError.elementNotFound(to)
        }
        let fromCenter = try centerOf(fromEl)
        let toCenter = try centerOf(toEl)
        try dragCoordinates(x1: Double(fromCenter.x), y1: Double(fromCenter.y),
                            x2: Double(toCenter.x), y2: Double(toCenter.y),
                            duration: duration)
    }

    public func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
        let durationMs = Int(duration * 1000)
        try runAdb(["shell", "input", "swipe",
                    "\(Int(x1))", "\(Int(y1))", "\(Int(x2))", "\(Int(y2))", "\(durationMs)"])
    }

    // MARK: - Keyboard

    public func pressKey(key: String) throws {
        let keycodes: [String: String] = [
            "home": "3", "back": "4", "enter": "66", "delete": "67",
            "tab": "61", "escape": "111", "volumeUp": "24", "volumeDown": "25",
            "power": "26"
        ]
        guard let code = keycodes[key] else {
            throw BridgeError.adbFailed("Unknown key: \(key)")
        }
        try runAdb(["shell", "input", "keyevent", code])
    }

    public func hideKeyboard() throws {
        try runAdb(["shell", "input", "keyevent", "111"]) // KEYCODE_ESCAPE
    }

    public func eraseText(count: Int) throws {
        for _ in 0..<count {
            try runAdb(["shell", "input", "keyevent", "67"]) // KEYCODE_DEL
        }
    }

    // MARK: - Text Extraction

    public func copyTextFrom(target: String) throws -> String {
        let tree = try dumpUITree()
        guard let element = findElement(in: tree, matching: target) else {
            throw BridgeError.elementNotFound(target)
        }
        // Return text or value attribute from the element
        if let text = element["title"] as? String, !text.isEmpty {
            return text
        }
        if let value = element["value"] as? String, !value.isEmpty {
            return value
        }
        if let label = element["label"] as? String, !label.isEmpty {
            return label
        }
        throw BridgeError.adbFailed("Element '\(target)' has no text content")
    }

    // MARK: - App Data

    public func clearState(bundleId: String) throws {
        try runAdb(["shell", "pm", "clear", bundleId])
    }

    public func uninstallApp(bundleId: String) throws {
        try runAdb(["uninstall", bundleId])
    }

    // MARK: - Scroll Search

    public func scrollTo(target: String, direction: String, maxAttempts: Int) throws {
        let screen = try getScreenSize()
        let cx = screen.width / 2
        let cy = screen.height / 2
        let scrollDistance = screen.height * 30 / 100

        let (x1, y1, x2, y2): (Int, Int, Int, Int)
        switch direction.lowercased() {
        case "up":    (x1, y1, x2, y2) = (cx, cy - scrollDistance / 2, cx, cy + scrollDistance / 2)
        case "down":  (x1, y1, x2, y2) = (cx, cy + scrollDistance / 2, cx, cy - scrollDistance / 2)
        case "left":  (x1, y1, x2, y2) = (cx - scrollDistance / 2, cy, cx + scrollDistance / 2, cy)
        case "right": (x1, y1, x2, y2) = (cx + scrollDistance / 2, cy, cx - scrollDistance / 2, cy)
        default:
            throw BridgeError.invalidDirection(direction)
        }

        for attempt in 0..<maxAttempts {
            let tree = try dumpUITree()
            if findElement(in: tree, matching: target) != nil {
                return
            }
            if attempt < maxAttempts - 1 {
                try runAdb(["shell", "input", "swipe", "\(x1)", "\(y1)", "\(x2)", "\(y2)", "300"])
                usleep(500_000) // Wait for scroll animation
            }
        }
        throw BridgeError.elementNotFound(target)
    }

    // MARK: - Screen Recording

    public func startRecording() throws {
        if recordingProcess != nil {
            throw BridgeError.adbFailed("Recording already in progress")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: try adbPath())

        var args = ["shell", "screenrecord", "/sdcard/autopilot-recording.mp4"]
        if let deviceId = selectedDeviceId {
            args = ["-s", deviceId] + args
        }
        process.arguments = args
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        try process.run()
        recordingProcess = process
    }

    public func stopRecording(outputPath: String) throws {
        guard let process = recordingProcess else {
            throw BridgeError.adbFailed("No recording in progress")
        }

        // Send SIGINT to stop recording gracefully
        process.interrupt()
        process.waitUntilExit()
        recordingProcess = nil

        // Wait for file to be finalized
        usleep(1_000_000)

        // Pull the recording file
        try runAdb(["pull", "/sdcard/autopilot-recording.mp4", outputPath])
        try runAdb(["shell", "rm", "/sdcard/autopilot-recording.mp4"])
    }

    // MARK: - Device Environment

    public func setLocation(latitude: Double, longitude: Double) throws {
        // NOTE: adb emu geo fix takes LONGITUDE first, then latitude
        try runAdb(["emu", "geo", "fix", "\(longitude)", "\(latitude)"])
    }

    public func setAppearance(mode: String) throws {
        switch mode.lowercased() {
        case "dark":
            try runAdb(["shell", "cmd", "uimode", "night", "yes"])
        case "light":
            try runAdb(["shell", "cmd", "uimode", "night", "no"])
        default:
            throw BridgeError.adbFailed("Invalid appearance mode: \(mode). Use 'dark' or 'light'")
        }
    }

    public func lockDevice() throws {
        try runAdb(["shell", "input", "keyevent", "26"]) // KEYCODE_POWER
    }

    public func unlockDevice() throws {
        try runAdb(["shell", "input", "keyevent", "82"]) // KEYCODE_MENU
        usleep(500_000)
        try runAdb(["shell", "input", "swipe", "540", "2000", "540", "800", "300"])
    }

    // MARK: - File Transfer

    public func pushFile(localPath: String, remotePath: String) throws {
        try runAdb(["push", localPath, remotePath])
    }

    public func pullFile(remotePath: String, localPath: String) throws {
        try runAdb(["pull", remotePath, localPath])
    }
}
