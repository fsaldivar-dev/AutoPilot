import Foundation
import CoreGraphics
import AutoCore

/// Controls iOS apps via the AutoPilot in-process observer (ARD-002).
/// The observer lib is linked into the iOS app at build time (-force_load)
/// and exposes a TCP socket at 127.0.0.1:7002 from inside the app process.
/// Communication: JSON over TCP socket, same protocol as Android AgentBridge.
public final class iOSAgentBridge: DeviceBridge {

    private let host: String
    private let port: Int

    public init(host: String = "127.0.0.1", port: Int = 7002) {
        self.host = host
        self.port = port
    }

    // MARK: - Socket Communication

    private func sendCommand(_ method: String, params: [String: Any]? = nil) throws -> Any {
        var request: [String: Any] = ["method": method]
        if let params = params {
            request["params"] = params
        }

        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard var requestString = String(data: requestData, encoding: .utf8) else {
            throw BridgeError.unknown("Failed to encode command")
        }
        requestString += "\n"

        let socket = try createSocket()
        defer { close(socket) }

        // Set a 10s recv timeout so we don't block forever on a silent tunnel.
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let sendData = requestString.data(using: .utf8) else {
            throw BridgeError.unknown("Failed to encode request")
        }
        // Send all bytes — loop until full payload dispatched (TCP can short-send).
        var sent = 0
        sendData.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            while sent < sendData.count {
                let n = send(socket, base.advanced(by: sent), sendData.count - sent, 0)
                if n <= 0 { break }
                sent += n
            }
        }

        var responseData = Data()
        let bufSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { buffer.deallocate() }

        outer: while true {
            let bytesRead = recv(socket, buffer, bufSize, 0)
            if bytesRead <= 0 { break }
            for i in 0..<bytesRead {
                if buffer[i] == 0x0A {
                    responseData.append(buffer, count: i)
                    break outer
                }
            }
            responseData.append(buffer, count: bytesRead)
        }

        guard !responseData.isEmpty else {
            // connectionFailed (no unknown): el socket murió a media corrida —
            // el ActionRouter degrada al XCUIBackend en vez de abortar (#154).
            throw BridgeError.connectionFailed("Empty response from observer (app may have crashed or restarted)")
        }

        let json = try JSONSerialization.jsonObject(with: responseData)
        guard let response = json as? [String: Any] else {
            throw BridgeError.unknown("Invalid JSON response from observer")
        }

        if let error = response["error"] as? String {
            // Rethrow as elementNotFound so ActionRouter can escalate to AX/XCUI.
            if error.lowercased().hasPrefix("element not found") {
                let target = String(error.dropFirst("element not found: ".count))
                throw BridgeError.elementNotFound(target)
            }
            throw BridgeError.adbFailed(error)
        }

        return response["result"] as Any
    }

    private func createSocket() throws -> Int32 {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw BridgeError.unknown("Failed to create socket")
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
            // Post-#164 el observer se INYECTA por defecto en `auto launch` —
            // el remedio ya no es recompilar. Mensaje neutro que cubre ambos
            // orígenes (inyección en simulator, build linkeado en device).
            throw BridgeError.connectionFailed("Cannot connect to observer at \(host):\(port). Relanza la app con `auto launch <bundle>` (la inyección del observer es default en simulator; en device físico va linkeado en el build)")
        }
        return sock
    }

    /// Non-throwing probe — returns true only if a ping round-trip succeeds within 1s.
    /// Fast for loopback (127.0.0.1): ECONNREFUSED is immediate. Do NOT call with
    /// non-loopback hosts — connect() blocks until OS timeout (~75s) on unreachable IPs.
    public func probeSocket() -> Bool {
        guard let sock = try? createSocket() else { return false }
        defer { close(sock) }

        let ping = "{\"method\":\"ping\"}\n"
        guard let data = ping.data(using: .utf8) else { return false }
        let sent = data.withUnsafeBytes { ptr in send(sock, ptr.baseAddress!, data.count, 0) }
        if sent <= 0 { return false }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 256)
        let bytesRead = recv(sock, &buf, buf.count, 0)
        return bytesRead > 0
    }

    /// Handshake #154: pide `ping` y devuelve el `bundleId` REAL del proceso
    /// que tiene el socket 7002 (el observer lo lee de `Bundle.main`). El
    /// puerto es fijo, así que otra app lanzada antes puede retenerlo — sin
    /// este check el CLI reporta "with observer" aunque el observer corra en
    /// OTRA app. Devuelve `nil` si el socket no responde o si el dylib es
    /// anterior al handshake (no reporta bundleId).
    public func observedBundleId() -> String? {
        guard let sock = try? createSocket() else { return nil }
        defer { close(sock) }

        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let ping = "{\"method\":\"ping\"}\n"
        guard let data = ping.data(using: .utf8) else { return nil }
        let sent = data.withUnsafeBytes { ptr in send(sock, ptr.baseAddress!, data.count, 0) }
        if sent <= 0 { return nil }

        var response = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(sock, &buf, buf.count, 0)
            if n <= 0 { break }
            if let nl = buf[0..<n].firstIndex(of: 0x0A) {
                response.append(contentsOf: buf[0..<nl])
                break
            }
            response.append(contentsOf: buf[0..<n])
        }

        guard !response.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
              let bundle = json["bundleId"] as? String, !bundle.isEmpty
        else { return nil }
        return bundle
    }

    /// Probe con reintentos hasta `deadlineMs` — el observer tarda unos ms en
    /// abrir el socket tras el launch (+load difiere al main queue). Usado por
    /// `auto launch` para reportar honestamente si el observer cargó (#164).
    public func probeSocketWithRetry(deadlineMs: Int) -> Bool {
        let steps = max(1, deadlineMs / 100)
        for _ in 0..<steps {
            if probeSocket() { return true }
            usleep(100_000)
        }
        return false
    }

    // MARK: - DeviceBridge: Tree (via observer)

    public func tree() throws -> [[String: Any]] {
        let result = try sendCommand("tree")
        guard let tree = result as? [[String: Any]] else {
            if let arr = result as? [Any] {
                return arr.compactMap { $0 as? [String: Any] }
            }
            throw BridgeError.unknown("Invalid tree response from observer")
        }
        return tree
    }

    public func search(query: String) throws -> [[String: Any]] {
        let allElements = try tree()
        let q = query.lowercased()
        return allElements.filter { node in
            let label = (node["label"] as? String ?? "").lowercased()
            let id = (node["identifier"] as? String ?? "").lowercased()
            let text = (node["text"] as? String ?? "").lowercased()
            let title = (node["title"] as? String ?? "").lowercased()
            return label.contains(q) || id.contains(q) || text.contains(q) || title.contains(q)
        }
    }

    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        let allElements = try tree()
        for node in allElements {
            guard let frameDict = node["frame"] as? [String: Any],
                  let fx = frameDict["x"] as? Double, let fy = frameDict["y"] as? Double,
                  let fw = frameDict["w"] as? Double, let fh = frameDict["h"] as? Double
            else { continue }
            let frame = CGRect(x: fx, y: fy, width: fw, height: fh)
            if frame.contains(CGPoint(x: x, y: y)) { return node }
        }
        return nil
    }

    // MARK: - DeviceBridge: Actions (via observer)

    public func tap(target: String) throws {
        let _ = try sendCommand("tap", params: ["target": target])
    }

    public func doubleTap(target: String) throws {
        let _ = try sendCommand("doubleTap", params: ["target": target])
    }

    public func longPress(target: String, duration: Double) throws {
        let _ = try sendCommand("longPress", params: ["target": target, "duration": Int(duration * 1000)])
    }

    public func clear(target: String) throws {
        let _ = try sendCommand("clear", params: ["target": target])
    }

    public func typeText(_ text: String) throws {
        let _ = try sendCommand("type", params: ["text": text])
    }

    public func scroll(target: String, direction: String) throws {
        let _ = try sendCommand("scroll", params: ["target": target, "direction": direction])
    }

    public func swipe(direction: String) throws {
        let _ = try sendCommand("swipe", params: ["direction": direction])
    }

    public func tapAtCoordinate(x: Double, y: Double) throws {
        let _ = try sendCommand("tapAt", params: ["x": x, "y": y])
    }

    public func drag(from: String, to: String, duration: Double) throws {
        throw BridgeError.unknown("drag not implemented in iOSAgentBridge Phase 1")
    }

    public func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
        throw BridgeError.unknown("dragCoordinates not implemented in iOSAgentBridge Phase 1")
    }

    public func pressKey(key: String) throws {
        let _ = try sendCommand("pressKey", params: ["key": key])
    }

    public func hideKeyboard() throws {
        let _ = try sendCommand("hideKeyboard")
    }

    public func eraseText(count: Int) throws {
        throw BridgeError.unknown("eraseText not implemented in iOSAgentBridge Phase 1")
    }

    public func copyTextFrom(target: String) throws -> String {
        throw BridgeError.unknown("copyTextFrom not implemented in iOSAgentBridge Phase 1")
    }

    public func viewport() throws -> CGRect {
        let result = try sendCommand("viewport")
        guard let r = result as? [String: Any],
              let x = r["x"] as? Double, let y = r["y"] as? Double,
              let w = r["w"] as? Double, let h = r["h"] as? Double
        else { throw BridgeError.unknown("Invalid viewport response") }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - DeviceBridge: Lifecycle (not supported — handled by SimCtlBackend)

    public func launchApp(bundleId: String, envVars: [String: String]) throws {
        throw BridgeError.unknown("launchApp not supported by iOSAgentBridge — use SimCtlBackend")
    }

    public func terminateApp(bundleId: String) throws {
        throw BridgeError.unknown("terminateApp not supported by iOSAgentBridge — use SimCtlBackend")
    }

    public func listDevices() throws -> [[String: Any]] {
        throw BridgeError.unknown("listDevices not supported by iOSAgentBridge")
    }

    public func bootDevice(_ nameOrUdid: String) throws {
        throw BridgeError.unknown("bootDevice not supported by iOSAgentBridge")
    }

    public func shutdownDevice(_ nameOrUdid: String) throws {
        throw BridgeError.unknown("shutdownDevice not supported by iOSAgentBridge")
    }

    public func installApp(path: String) throws {
        throw BridgeError.unknown("installApp not supported by iOSAgentBridge")
    }

    public func getBootedDeviceId() throws -> String {
        throw BridgeError.unknown("getBootedDeviceId not supported by iOSAgentBridge")
    }

    public func screenshot(path: String) throws {
        throw BridgeError.unknown("screenshot not supported by iOSAgentBridge — use MediaBackend")
    }

    public func addMedia(path: String) throws {
        throw BridgeError.unknown("addMedia not supported by iOSAgentBridge")
    }

    public func openURL(_ url: String) throws {
        throw BridgeError.unknown("openURL not supported by iOSAgentBridge")
    }

    public func setPasteboard(text: String) throws {
        throw BridgeError.unknown("setPasteboard not supported by iOSAgentBridge")
    }

    public func getPasteboard() throws -> String {
        throw BridgeError.unknown("getPasteboard not supported by iOSAgentBridge")
    }

    public func biometricEnroll() throws {
        throw BridgeError.unknown("biometricEnroll not supported by iOSAgentBridge")
    }

    public func biometricUnenroll() throws {
        throw BridgeError.unknown("biometricUnenroll not supported by iOSAgentBridge")
    }

    public func biometricMatch() throws {
        throw BridgeError.unknown("biometricMatch not supported by iOSAgentBridge")
    }

    public func biometricFail() throws {
        throw BridgeError.unknown("biometricFail not supported by iOSAgentBridge")
    }

    public func biometricIsEnrolled() throws -> Bool {
        throw BridgeError.unknown("biometricIsEnrolled not supported by iOSAgentBridge")
    }

    public func getLogs(bundleId: String?, lines: Int) throws -> String {
        throw BridgeError.unknown("getLogs not supported by iOSAgentBridge")
    }

    public func setPermission(action: String, service: String, bundleId: String) throws {
        throw BridgeError.unknown("setPermission not supported by iOSAgentBridge")
    }

    public func rotate(direction: String) throws {
        throw BridgeError.unknown("rotate not supported by iOSAgentBridge")
    }

    public func clearState(bundleId: String) throws {
        throw BridgeError.unknown("clearState not supported by iOSAgentBridge")
    }

    public func uninstallApp(bundleId: String) throws {
        throw BridgeError.unknown("uninstallApp not supported by iOSAgentBridge")
    }

    public func startRecording() throws {
        throw BridgeError.unknown("startRecording not supported by iOSAgentBridge")
    }

    public func stopRecording(outputPath: String) throws {
        throw BridgeError.unknown("stopRecording not supported by iOSAgentBridge")
    }

    public func setLocation(latitude: Double, longitude: Double) throws {
        throw BridgeError.unknown("setLocation not supported by iOSAgentBridge")
    }

    public func setAppearance(mode: String) throws {
        throw BridgeError.unknown("setAppearance not supported by iOSAgentBridge")
    }

    public func lockDevice() throws {
        throw BridgeError.unknown("lockDevice not supported by iOSAgentBridge")
    }

    public func unlockDevice() throws {
        throw BridgeError.unknown("unlockDevice not supported by iOSAgentBridge")
    }

    public func pushFile(localPath: String, remotePath: String) throws {
        throw BridgeError.unknown("pushFile not supported by iOSAgentBridge")
    }

    public func pullFile(remotePath: String, localPath: String) throws {
        throw BridgeError.unknown("pullFile not supported by iOSAgentBridge")
    }
}
