import Foundation

/// Controls Android devices via the AutoPilot agent (socket connection).
/// The agent runs on the device as an instrumentation APK with UiAutomation access.
/// Communication: JSON over TCP socket (adb forward localabstract:autopilot).
public final class AgentBridge: DeviceBridge {

    private let host: String
    private let port: Int
    private let legacy: AdbLegacyBridge

    /// Set to false to skip auto-recovery (for setup command, doctor, tests)
    public var autoRecover: Bool = true

    public init(host: String = "127.0.0.1", port: Int = 9008) {
        self.host = host
        self.port = port
        self.legacy = AdbLegacyBridge()
    }

    // MARK: - Socket Communication

    private func sendCommand(_ method: String, params: [String: Any]? = nil) throws -> Any {
        return try sendCommandInternal(method, params: params, allowRecover: autoRecover)
    }

    private func sendCommandInternal(_ method: String, params: [String: Any]?, allowRecover: Bool) throws -> Any {
        var request: [String: Any] = ["method": method]
        if let params = params {
            request["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard var requestString = String(data: requestData, encoding: .utf8) else {
            throw BridgeError.adbFailed("Failed to encode command")
        }
        requestString += "\n"

        // Connect (with auto-recovery on Connection refused)
        let socket: Int32
        do {
            socket = try createSocket()
        } catch {
            if allowRecover {
                // Try to recover: rearm forward + (optionally) relaunch agent
                try recoverAgent()
                // Retry once with recovery disabled to avoid infinite loop
                return try sendCommandInternal(method, params: params, allowRecover: false)
            }
            throw error
        }
        defer { close(socket) }

        // Send
        guard let sendData = requestString.data(using: .utf8) else {
            throw BridgeError.adbFailed("Failed to encode request")
        }
        let _ = sendData.withUnsafeBytes { ptr in
            send(socket, ptr.baseAddress!, sendData.count, 0)
        }

        // Read response (one line terminated by \n)
        var responseData = Data()
        let bufSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }

        outer: while true {
            let bytesRead = recv(socket, buffer, bufSize, 0)
            if bytesRead <= 0 { break }
            for i in 0..<bytesRead {
                if buffer[i] == 0x0A { // newline = end of response
                    responseData.append(buffer, count: i)
                    break outer
                }
            }
            responseData.append(buffer, count: bytesRead)
        }

        guard !responseData.isEmpty else {
            // Empty response = socket closed mid-read (agent crashed). Recover if allowed.
            if allowRecover {
                try recoverAgent()
                return try sendCommandInternal(method, params: params, allowRecover: false)
            }
            throw BridgeError.adbFailed("Empty response from agent (agent may have crashed)")
        }

        // Parse JSON
        let json = try JSONSerialization.jsonObject(with: responseData)
        guard let response = json as? [String: Any] else {
            throw BridgeError.adbFailed("Invalid JSON response")
        }

        // Check for error
        if let error = response["error"] as? String {
            throw BridgeError.adbFailed(error)
        }

        return response["result"] as Any
    }

    private func createSocket() throws -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw BridgeError.adbFailed("Failed to create socket")
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            close(sock)
            throw BridgeError.adbFailed("Cannot connect to agent at \(host):\(port). Is the agent running?")
        }

        return sock
    }

    // MARK: - Auto-Recovery (#66, #67, #68)

    /// Internal recovery: rearma adb forward y, si el socket sigue caido, relanza el agente.
    /// Es invocado automaticamente por sendCommand cuando detecta socket cerrado / Connection refused.
    private func recoverAgent() throws {
        // Step 1: rearm adb forward (cheap, fixes most cases)
        do {
            try legacy.runAdbPublic(["forward", "tcp:\(port)", "localabstract:autopilot"])
        } catch {
            // adb may not be available — propagate clear error
            throw BridgeError.adbFailed("Recovery failed: cannot run 'adb forward' — \(error)")
        }

        // Step 2: probe socket — if forward alone fixed it, no need to relaunch agent
        if probeSocket() { return }

        // Step 3: relaunch agent via instrumentation. Detached so it survives this process.
        relaunchAgentDetached()

        // Step 4: wait up to 3s for agent to come up
        for _ in 0..<15 {
            usleep(200_000) // 200ms
            if probeSocket() { return }
        }

        // Step 5: still down — propagate clear error
        throw BridgeError.adbFailed("""
            Agent did not respond after recovery. Check:
              1. APK installed: adb install agent/app/build/outputs/apk/debug/app-debug.apk
              2. Manually launch: adb shell am instrument -w dev.autopilot.agent/.AgentInstrumentation
              3. Run: auto-android doctor
            """)
    }

    /// Probe non-throwing: returns true if socket connect succeeds.
    private func probeSocket() -> Bool {
        guard let sock = try? createSocket() else { return false }
        close(sock)
        return true
    }

    /// Launch the agent via `am instrument` in background, detached from this process.
    private func relaunchAgentDetached() {
        guard let adb = try? legacy.adbPathPublic() else { return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: adb)
        proc.arguments = ["shell", "am", "instrument", "-w", "dev.autopilot.agent/.AgentInstrumentation"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        // Don't wait — instrument runs the agent process; it would block forever.
    }

    /// Public setup entry point — used by `auto-android setup` command (#67).
    /// Runs the same recovery flow but with verbose output.
    public func setupAgent(verbose: Bool = true) throws {
        if verbose { print("→ adb forward tcp:\(port) localabstract:autopilot") }
        try legacy.runAdbPublic(["forward", "tcp:\(port)", "localabstract:autopilot"])

        if probeSocket() {
            if verbose { print("✓ Agent already running and reachable") }
            return
        }

        if verbose { print("→ Launching agent via am instrument") }
        relaunchAgentDetached()

        for i in 0..<15 {
            usleep(200_000)
            if probeSocket() {
                if verbose { print("✓ Agent ready (\((i + 1) * 200)ms)") }
                return
            }
        }

        throw BridgeError.adbFailed("Agent did not come up after 3s. Check that the APK is installed.")
    }

    // MARK: - DeviceBridge: Tree (via agent)

    public func tree() throws -> [[String: Any]] {
        let result = try sendCommand("tree")
        guard let tree = result as? [[String: Any]] else {
            // Try unwrapping from JSONSerialization format
            if let arr = result as? [Any] {
                return arr.compactMap { $0 as? [String: Any] }
            }
            throw BridgeError.adbFailed("Invalid tree response")
        }
        return tree
    }

    public func search(query: String) throws -> [[String: Any]] {
        let tree = try tree()
        var results: [[String: Any]] = []
        searchRecursive(elements: tree, query: query.lowercased(), results: &results)
        return results
    }

    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        let tree = try tree()
        return findDeepest(in: tree, x: x, y: y)
    }

    // MARK: - DeviceBridge: Actions (via agent)

    public func tap(target: String) throws {
        let _ = try sendCommand("tap", params: ["target": target])
    }

    public func longPress(target: String, duration: Double) throws {
        let _ = try sendCommand("longPress", params: ["target": target, "duration": Int(duration * 1000)])
    }

    public func doubleTap(target: String) throws {
        let _ = try sendCommand("doubleTap", params: ["target": target])
    }

    public func clear(target: String) throws {
        let _ = try sendCommand("clear", params: ["target": target])
    }

    public func typeText(_ text: String) throws {
        let _ = try sendCommand("type", params: ["text": text])
    }

    public func scroll(target: String, direction: String) throws {
        // Find element via tree, then swipe within its bounds
        let tree = try tree()
        guard let element = findElement(in: tree, matching: target) else {
            throw BridgeError.elementNotFound(target)
        }
        guard let frame = element["frame"] as? [String: Any],
              let x = frame["x"] as? Int, let y = frame["y"] as? Int,
              let w = frame["width"] as? Int, let h = frame["height"] as? Int else {
            throw BridgeError.noFrame(target)
        }

        let cx = x + w / 2
        let cy = y + h / 2
        let distance = min(h * 40 / 100, 200)

        let (x1, y1, x2, y2): (Int, Int, Int, Int) = switch direction.lowercased() {
            case "up": (cx, cy, cx, cy - distance)
            case "down": (cx, cy, cx, cy + distance)
            case "left": (cx, cy, cx - min(w * 40 / 100, 200), cy)
            case "right": (cx, cy, cx + min(w * 40 / 100, 200), cy)
            default: throw BridgeError.invalidDirection(direction)
        }

        let _ = try sendCommand("swipe", params: ["x1": x1, "y1": y1, "x2": x2, "y2": y2])
    }

    public func swipe(direction: String) throws {
        let _ = try sendCommand("swipe", params: ["direction": direction])
    }

    public func tapAtCoordinate(x: Double, y: Double) throws {
        let _ = try sendCommand("tapAt", params: ["x": Int(x), "y": Int(y)])
    }

    // MARK: - DeviceBridge: App/Device (via adb — agent doesn't handle these yet)

    public func launchApp(bundleId: String, envVars: [String: String]) throws {
        try legacy.launchApp(bundleId: bundleId, envVars: envVars)
    }

    public func terminateApp(bundleId: String) throws {
        try legacy.terminateApp(bundleId: bundleId)
    }

    public func listDevices() throws -> [[String: Any]] {
        try legacy.listDevices()
    }

    public func bootDevice(_ nameOrUdid: String) throws {
        try legacy.bootDevice(nameOrUdid)
    }

    public func shutdownDevice(_ nameOrUdid: String) throws {
        try legacy.shutdownDevice(nameOrUdid)
    }

    public func installApp(path: String) throws {
        try legacy.installApp(path: path)
    }

    public func getBootedDeviceId() throws -> String {
        try legacy.getBootedDeviceId()
    }

    // MARK: - DeviceBridge: Media & IO (via adb)

    public func screenshot(path: String) throws {
        try legacy.screenshot(path: path)
    }

    public func addMedia(path: String) throws {
        try legacy.addMedia(path: path)
    }

    public func openURL(_ url: String) throws {
        try legacy.openURL(url)
    }

    public func setPasteboard(text: String) throws {
        let _ = try sendCommand("setClipboard", params: ["text": text])
    }

    public func getPasteboard() throws -> String {
        let result = try sendCommand("getClipboard")
        if let text = result as? String {
            return text
        }
        throw BridgeError.adbFailed("Invalid clipboard response")
    }

    // MARK: - Drag

    public func drag(from: String, to: String, duration: Double) throws {
        let currentTree = try tree()
        guard let fromEl = findElement(in: currentTree, matching: from) else {
            throw BridgeError.elementNotFound(from)
        }
        guard let toEl = findElement(in: currentTree, matching: to) else {
            throw BridgeError.elementNotFound(to)
        }
        guard let fromFrame = fromEl["frame"] as? [String: Any],
              let fx = (fromFrame["x"] as? Int).map(Double.init) ?? fromFrame["x"] as? Double,
              let fy = (fromFrame["y"] as? Int).map(Double.init) ?? fromFrame["y"] as? Double,
              let fw = (fromFrame["width"] as? Int).map(Double.init) ?? fromFrame["width"] as? Double,
              let fh = (fromFrame["height"] as? Int).map(Double.init) ?? fromFrame["height"] as? Double else {
            throw BridgeError.noFrame(from)
        }
        guard let toFrame = toEl["frame"] as? [String: Any],
              let tx = (toFrame["x"] as? Int).map(Double.init) ?? toFrame["x"] as? Double,
              let ty = (toFrame["y"] as? Int).map(Double.init) ?? toFrame["y"] as? Double,
              let tw = (toFrame["width"] as? Int).map(Double.init) ?? toFrame["width"] as? Double,
              let th = (toFrame["height"] as? Int).map(Double.init) ?? toFrame["height"] as? Double else {
            throw BridgeError.noFrame(to)
        }
        try dragCoordinates(x1: fx + fw / 2, y1: fy + fh / 2,
                            x2: tx + tw / 2, y2: ty + th / 2,
                            duration: duration)
    }

    public func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
        let _ = try sendCommand("swipe", params: [
            "x1": Int(x1), "y1": Int(y1),
            "x2": Int(x2), "y2": Int(y2),
            "duration": Int(duration * 1000)
        ])
    }

    // MARK: - Camera mock (JVMTI agent injection)

    private static let deviceTmpDir = "/data/local/tmp"
    private static let agentSoName = "libcameramock.so"
    private static let agentDexName = "autopilot-camera-mock.dex"
    private static let mockImageName = "camera.jpg"

    /// Validate Android package name to prevent shell injection.
    private func validatePackage(_ pkg: String) throws -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        guard !pkg.isEmpty,
              pkg.unicodeScalars.allSatisfy({ allowed.contains($0) }),
              pkg.contains(".") else {
            throw BridgeError.adbFailed("Invalid package name: \(pkg)")
        }
        return pkg
    }

    /// Start camera mock: deploy agent + image, attach to running app.
    public func cameraStart(imagePath: String, package: String) throws {
        let pkg = try validatePackage(package)
        let resolvedImage = resolvePath(imagePath)
        guard FileManager.default.fileExists(atPath: resolvedImage) else {
            throw BridgeError.adbFailed("Image not found: \(resolvedImage)")
        }

        // Find bundled agent files next to the CLI binary
        let agentDir = try findAgentBuildDir()
        let soPath = agentDir + "/\(Self.agentSoName)"
        let dexPath = agentDir + "/\(Self.agentDexName)"

        guard FileManager.default.fileExists(atPath: soPath) else {
            throw BridgeError.adbFailed("Agent .so not found: \(soPath). Run agent/camera-mock-native/build.sh first.")
        }
        guard FileManager.default.fileExists(atPath: dexPath) else {
            throw BridgeError.adbFailed("Agent .dex not found: \(dexPath). Run agent/camera-mock-kotlin/build.sh first.")
        }

        // 1. Push files to /data/local/tmp/
        try legacy.runAdbPublic(["push", soPath, "\(Self.deviceTmpDir)/\(Self.agentSoName)"])
        try legacy.runAdbPublic(["push", dexPath, "\(Self.deviceTmpDir)/\(Self.agentDexName)"])
        try legacy.runAdbPublic(["push", resolvedImage, "\(Self.deviceTmpDir)/\(Self.mockImageName)"])

        // 2. Copy into app's data dir via run-as (SELinux requires this)
        try legacy.runAdbPublic(["shell", "run-as", pkg, "rm", "-f", Self.agentSoName, Self.agentDexName, Self.mockImageName])
        try legacy.runAdbPublic(["shell", "run-as", pkg, "cp", "\(Self.deviceTmpDir)/\(Self.agentSoName)", "./\(Self.agentSoName)"])
        try legacy.runAdbPublic(["shell", "run-as", pkg, "cp", "\(Self.deviceTmpDir)/\(Self.agentDexName)", "./\(Self.agentDexName)"])
        try legacy.runAdbPublic(["shell", "run-as", pkg, "chmod", "444", Self.agentDexName])
        try legacy.runAdbPublic(["shell", "run-as", pkg, "cp", "\(Self.deviceTmpDir)/\(Self.mockImageName)", "./\(Self.mockImageName)"])

        // 3. Get PID and data dir
        let pidStr = try legacy.runAdbPublic(["shell", "pidof", pkg]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pidStr.isEmpty else {
            throw BridgeError.adbFailed("App not running: \(pkg). Launch it first.")
        }
        let dataDir = try legacy.runAdbPublic(["shell", "run-as", pkg, "pwd"]).trimmingCharacters(in: .whitespacesAndNewlines)

        // 4. Attach JVMTI agent
        let agentArg = "\(dataDir)/\(Self.agentSoName)=\(dataDir)/\(Self.mockImageName)"
        try legacy.runAdbPublic(["shell", "cmd", "activity", "attach-agent", pidStr, agentArg])
    }

    /// Update mock camera image (hot-swap — ImageWatcher detects the change).
    public func cameraFeed(imagePath: String, package: String) throws {
        let pkg = try validatePackage(package)
        let resolvedImage = resolvePath(imagePath)
        guard FileManager.default.fileExists(atPath: resolvedImage) else {
            throw BridgeError.adbFailed("Image not found: \(resolvedImage)")
        }

        try legacy.runAdbPublic(["push", resolvedImage, "\(Self.deviceTmpDir)/\(Self.mockImageName)"])
        try legacy.runAdbPublic(["shell", "run-as", pkg, "cp", "\(Self.deviceTmpDir)/\(Self.mockImageName)", "./\(Self.mockImageName)"])
    }

    /// Stop camera mock by force-stopping the app.
    public func cameraStop(package: String) throws {
        let pkg = try validatePackage(package)
        try legacy.runAdbPublic(["shell", "am", "force-stop", pkg])
    }

    /// Launch app with camera mock injection (JVMTI).
    /// Equivalent to iOS's `injectAndLaunch` — one command for both platforms.
    public func injectAndLaunch(bundleId: String, imagePath: String) throws {
        let pkg = try validatePackage(bundleId)
        let resolvedImage = resolvePath(imagePath)
        guard FileManager.default.fileExists(atPath: resolvedImage) else {
            throw BridgeError.adbFailed("Image not found: \(resolvedImage)")
        }

        // 1. Launch the app
        try launchApp(bundleId: pkg, envVars: [:])

        // 2. Wait for app process to start
        usleep(2_000_000) // 2 seconds

        // 3. Attach JVMTI agent with camera hooks
        try cameraStart(imagePath: resolvedImage, package: pkg)
    }

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") { return path }
        return FileManager.default.currentDirectoryPath + "/" + path
    }

    private func findAgentBuildDir() throws -> String {
        // Look for pre-built files relative to the repo root
        // Convention: agent/camera-mock-native/build/ has .so, agent/camera-mock-kotlin/build/ has .dex
        let cwd = FileManager.default.currentDirectoryPath
        let fm = FileManager.default

        // Try relative to cwd (user is in repo root)
        let nativeBuild = cwd + "/agent/camera-mock-native/build"
        let kotlinBuild = cwd + "/agent/camera-mock-kotlin/build"

        // Check for .so in native build dir — use arm64 by default
        let soArm64 = nativeBuild + "/libcameramock-arm64.so"
        let soGeneric = nativeBuild + "/libcameramock.so"
        guard fm.fileExists(atPath: soArm64) || fm.fileExists(atPath: soGeneric) else {
            throw BridgeError.adbFailed("Camera mock .so not found in \(nativeBuild). Run build.sh first.")
        }

        // For the .so, prefer arm64 variant
        if fm.fileExists(atPath: soArm64) && !fm.fileExists(atPath: soGeneric) {
            try? fm.copyItem(atPath: soArm64, toPath: soGeneric)
        }

        // Check .dex exists
        let dexPath = kotlinBuild + "/\(Self.agentDexName)"
        guard fm.fileExists(atPath: dexPath) else {
            throw BridgeError.adbFailed("Camera mock .dex not found at \(dexPath). Run build.sh first.")
        }

        // Create a combined staging dir in /tmp
        let staging = "/tmp/autopilot-camera-agent"
        try? fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        try? fm.removeItem(atPath: staging + "/\(Self.agentSoName)")
        try? fm.removeItem(atPath: staging + "/\(Self.agentDexName)")

        if fm.fileExists(atPath: soArm64) {
            try fm.copyItem(atPath: soArm64, toPath: staging + "/\(Self.agentSoName)")
        } else {
            try fm.copyItem(atPath: soGeneric, toPath: staging + "/\(Self.agentSoName)")
        }
        try fm.copyItem(atPath: dexPath, toPath: staging + "/\(Self.agentDexName)")

        return staging
    }

    // MARK: - DeviceBridge: Biometric (via adb emu)

    public func biometricEnroll() throws {
        try legacy.biometricEnroll()
    }

    public func biometricUnenroll() throws {
        try legacy.biometricUnenroll()
    }

    public func biometricMatch() throws {
        try legacy.biometricMatch()
    }

    public func biometricFail() throws {
        try legacy.biometricFail()
    }

    public func biometricIsEnrolled() throws -> Bool {
        try legacy.biometricIsEnrolled()
    }

    // MARK: - Logs

    public func getLogs(bundleId: String?, lines: Int) throws -> String {
        try legacy.getLogs(bundleId: bundleId, lines: lines)
    }

    // MARK: - Permissions

    public func setPermission(action: String, service: String, bundleId: String) throws {
        try legacy.setPermission(action: action, service: service, bundleId: bundleId)
    }


    // MARK: - Device Orientation

    public func rotate(direction: String) throws {
        try legacy.rotate(direction: direction)
    }

    // MARK: - Helpers

    private func searchRecursive(elements: [[String: Any]], query: String, results: inout [[String: Any]]) {
        for el in elements {
            let title = (el["title"] as? String ?? "").lowercased()
            let label = (el["label"] as? String ?? "").lowercased()
            let identifier = (el["identifier"] as? String ?? "").lowercased()

            if title.contains(query) || label.contains(query) || identifier.contains(query) {
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

            if title == q || label == q || identifier == q { return el }
            if let children = el["children"] as? [[String: Any]] {
                if let found = findElement(in: children, matching: query) { return found }
            }
        }
        // Second pass: contains
        return findContains(in: tree, query: q)
    }

    private func findContains(in tree: [[String: Any]], query: String) -> [String: Any]? {
        for el in tree {
            let title = (el["title"] as? String ?? "").lowercased()
            let label = (el["label"] as? String ?? "").lowercased()
            if title.contains(query) || label.contains(query) { return el }
            if let children = el["children"] as? [[String: Any]] {
                if let found = findContains(in: children, query: query) { return found }
            }
        }
        return nil
    }

    private func findDeepest(in tree: [[String: Any]], x: Double, y: Double) -> [String: Any]? {
        var best: [String: Any]?
        var bestArea = Int.max

        func recurse(_ elements: [[String: Any]]) {
            for el in elements {
                if let frame = el["frame"] as? [String: Any],
                   let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
                   let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                    if x >= Double(fx) && x <= Double(fx + fw) && y >= Double(fy) && y <= Double(fy + fh) {
                        let area = fw * fh
                        if area < bestArea { bestArea = area; best = el }
                    }
                }
                if let children = el["children"] as? [[String: Any]] { recurse(children) }
            }
        }
        recurse(tree)
        return best
    }

    // MARK: - DeviceBridge: Keyboard & Text (via adb)

    public func pressKey(key: String) throws {
        try legacy.pressKey(key: key)
    }

    public func hideKeyboard() throws {
        try legacy.hideKeyboard()
    }

    public func eraseText(count: Int) throws {
        try legacy.eraseText(count: count)
    }

    public func copyTextFrom(target: String) throws -> String {
        let currentTree = try tree()
        guard let element = findElement(in: currentTree, matching: target) else {
            throw BridgeError.elementNotFound(target)
        }
        return element["text"] as? String ?? element["label"] as? String ?? ""
    }

    // MARK: - DeviceBridge: App Lifecycle (via adb)

    public func clearState(bundleId: String) throws {
        try legacy.clearState(bundleId: bundleId)
    }

    public func uninstallApp(bundleId: String) throws {
        try legacy.uninstallApp(bundleId: bundleId)
    }

    // MARK: - DeviceBridge: Scroll To (via agent + adb)

    public func scrollTo(target: String, direction: String, maxAttempts: Int) throws {
        for _ in 0..<maxAttempts {
            let results = try search(query: target)
            if !results.isEmpty {
                return
            }
            try scroll(target: "", direction: direction)
            usleep(500_000)
        }
        throw BridgeError.elementNotFound("'\(target)' not found after \(maxAttempts) scroll attempts")
    }

    // MARK: - DeviceBridge: Recording (via adb)

    public func startRecording() throws {
        try legacy.startRecording()
    }

    public func stopRecording(outputPath: String) throws {
        try legacy.stopRecording(outputPath: outputPath)
    }

    // MARK: - DeviceBridge: Device Settings (via adb)

    public func setLocation(latitude: Double, longitude: Double) throws {
        try legacy.setLocation(latitude: latitude, longitude: longitude)
    }

    public func setAppearance(mode: String) throws {
        try legacy.setAppearance(mode: mode)
    }

    public func lockDevice() throws {
        try legacy.lockDevice()
    }

    public func unlockDevice() throws {
        try legacy.unlockDevice()
    }

    // MARK: - DeviceBridge: File Transfer (via adb)

    public func pushFile(localPath: String, remotePath: String) throws {
        try legacy.pushFile(localPath: localPath, remotePath: remotePath)
    }

    public func pullFile(remotePath: String, localPath: String) throws {
        try legacy.pullFile(remotePath: remotePath, localPath: localPath)
    }
}
