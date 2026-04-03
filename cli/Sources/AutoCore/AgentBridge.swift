import Foundation

/// Controls Android devices via the AutoPilot agent (socket connection).
/// The agent runs on the device as an instrumentation APK with UiAutomation access.
/// Communication: JSON over TCP socket (adb forward localabstract:autopilot).
public final class AgentBridge: DeviceBridge {

    private let host: String
    private let port: Int
    private let legacy: AdbLegacyBridge

    public init(host: String = "127.0.0.1", port: Int = 9008) {
        self.host = host
        self.port = port
        self.legacy = AdbLegacyBridge()
    }

    // MARK: - Socket Communication

    private func sendCommand(_ method: String, params: [String: Any]? = nil) throws -> Any {
        var request: [String: Any] = ["method": method]
        if let params = params {
            request["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard var requestString = String(data: requestData, encoding: .utf8) else {
            throw BridgeError.adbFailed("Failed to encode command")
        }
        requestString += "\n"

        // Connect
        let socket = try createSocket()
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
            throw BridgeError.adbFailed("Empty response from agent")
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
        try typeText(text)
    }

    public func getPasteboard() throws -> String {
        throw BridgeError.adbFailed("Clipboard read not supported via ADB")
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
}
