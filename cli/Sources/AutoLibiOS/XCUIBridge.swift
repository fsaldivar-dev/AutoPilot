import Foundation
import AutoCore

// MARK: - XCUIBridge
//
// DeviceBridge implementation that talks DIRECTLY to the XCTest runner's
// TCP loopback port (default 127.0.0.1:22087). The daemon (autopilotd)
// is only used for lifecycle (start/stop the runner process); data calls
// bypass it entirely to minimize latency.
//
// Protocol: JSON over newline (same as AgentBridge on Android).
//
// Hot-path methods (tap, typeText, waitFor, tree, search, exists,
// screenshot, launch, terminate) are forwarded to the runner.
// Non-hot-path methods throw .unknown("not implemented in XCUI")
// so HybridBridge can fall back to SimulatorBridge.

public final class XCUIBridge: DeviceBridge {

    /// Runner's TCP server port (loopback inside the simulator).
    /// Matches AUTOPILOT_RUNNER_PORT in the runner (default 22087).
    public static let runnerPort: UInt16 = 22087

    private let host: String
    private let port: UInt16

    public init(host: String = "127.0.0.1", port: UInt16 = XCUIBridge.runnerPort) {
        self.host = host
        self.port = port
    }

    // MARK: - Socket Communication (direct TCP to runner)

    private func sendCommand(_ method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        // FAST PATH — direct TCP to runner (warm, ~500ms)
        if let fd = connectTCP(host: host, port: port) {
            defer { close(fd) }
            return try exchange(fd: fd, method: method, params: params)
        }

        // FALLBACK — contact daemon via Unix socket to auto-boot the runner.
        // After the first call, the runner is up and subsequent calls go direct.
        guard let daemonFD = connectDaemonUnixSocket() else {
            throw BridgeError.unknown(
                "cannot connect to XCUI runner at \(host):\(port) nor to autopilotd. " +
                "Start the daemon: ./scripts/demo/start-daemon.sh start"
            )
        }
        defer { close(daemonFD) }

        return try exchange(fd: daemonFD, method: method, params: params)
    }

    /// Shared send/recv loop over an open socket fd.
    private func exchange(fd: Int32, method: String, params: [String: Any]?) throws -> [String: Any] {

        // Build request
        var request: [String: Any] = ["method": method]
        if let params = params { request["params"] = params }

        let requestData = try JSONSerialization.data(withJSONObject: request)
        guard var requestStr = String(data: requestData, encoding: .utf8) else {
            throw BridgeError.unknown("failed to encode command")
        }
        requestStr += "\n"

        // Send
        _ = requestStr.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

        // Read response until \n
        var responseData = Data()
        let bufSize = 65536
        var buf = [UInt8](repeating: 0, count: bufSize)

        outer: while true {
            let n = recv(fd, &buf, bufSize, 0)
            if n <= 0 { break }
            for i in 0..<n {
                if buf[i] == 0x0A {
                    responseData.append(buf, count: i)
                    break outer
                }
            }
            responseData.append(buf, count: n)
        }

        guard !responseData.isEmpty else {
            throw BridgeError.unknown("empty response from runner")
        }

        // Parse
        let json = try JSONSerialization.jsonObject(with: responseData)
        guard let response = json as? [String: Any] else {
            throw BridgeError.unknown("invalid JSON from runner")
        }

        if let ok = response["ok"] as? Bool, !ok {
            let errMsg = response["error"] as? String ?? "unknown error"
            if errMsg.contains("element not found") {
                throw BridgeError.elementNotFound(errMsg)
            }
            throw BridgeError.unknown(errMsg)
        }

        return response["result"] as? [String: Any] ?? [:]
    }

    // MARK: - Hot-path

    public func tree() throws -> [[String: Any]] {
        let result = try sendCommand("tree")
        if let tree = result["tree"] as? [String: Any] {
            return [tree]
        }
        return []
    }

    public func search(query: String) throws -> [[String: Any]] {
        let result = try sendCommand("search", params: ["query": query])
        return result["matches"] as? [[String: Any]] ?? []
    }

    /// Fast typed listing. Returns a flat array of elements of the given type(s).
    /// - Parameter type: one of "all", "buttons", "labels", "statictexts",
    ///   "textfields", "cells", "switches", "links", "images", "navbars".
    ///   Caller is responsible for validating the type string.
    public func list(type: String) throws -> [[String: Any]] {
        let result = try sendCommand("list", params: ["type": type])
        return result["items"] as? [[String: Any]] ?? []
    }

    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        throw notImplemented("elementAt")
    }

    public func tap(target: String) throws {
        _ = try sendCommand("tap", params: ["target": target])
    }

    public func longPress(target: String, duration: Double) throws {
        _ = try sendCommand("longPress", params: ["target": target, "duration": duration])
    }

    public func doubleTap(target: String) throws {
        _ = try sendCommand("doubleTap", params: ["target": target])
    }

    public func clear(target: String) throws {
        _ = try sendCommand("clear", params: ["target": target])
    }

    public func typeText(_ text: String) throws {
        _ = try sendCommand("typeText", params: ["text": text])
    }

    public func scroll(target: String, direction: String) throws {
        _ = try sendCommand("scroll", params: ["target": target, "direction": direction])
    }

    public func swipe(direction: String) throws {
        _ = try sendCommand("swipe", params: ["direction": direction])
    }

    public func tapAtCoordinate(x: Double, y: Double) throws {
        throw notImplemented("tapAtCoordinate")
    }

    public func launchApp(bundleId: String, envVars: [String: String]) throws {
        var params: [String: Any] = ["bundleId": bundleId]
        if !envVars.isEmpty { params["envVars"] = envVars }
        _ = try sendCommand("launch", params: params)
    }

    public func terminateApp(bundleId: String) throws {
        _ = try sendCommand("terminate", params: ["bundleId": bundleId])
    }

    public func screenshot(path: String) throws {
        _ = try sendCommand("screenshot", params: ["path": path])
    }

    // MARK: - Not implemented in XCUI (fallback to fast-path via HybridBridge)

    public func listDevices() throws -> [[String: Any]]     { throw notImplemented("listDevices") }
    public func bootDevice(_ n: String) throws              { throw notImplemented("bootDevice") }
    public func shutdownDevice(_ n: String) throws          { throw notImplemented("shutdownDevice") }
    public func installApp(path: String) throws             { throw notImplemented("installApp") }
    public func getBootedDeviceId() throws -> String        { throw notImplemented("getBootedDeviceId") }
    public func addMedia(path: String) throws               { throw notImplemented("addMedia") }
    public func openURL(_ url: String) throws               { throw notImplemented("openURL") }
    public func setPasteboard(text: String) throws          { throw notImplemented("setPasteboard") }
    public func getPasteboard() throws -> String            { throw notImplemented("getPasteboard") }
    public func biometricEnroll() throws                    { throw notImplemented("biometricEnroll") }
    public func biometricUnenroll() throws                  { throw notImplemented("biometricUnenroll") }
    public func biometricMatch() throws                     { throw notImplemented("biometricMatch") }
    public func biometricFail() throws                      { throw notImplemented("biometricFail") }
    public func biometricIsEnrolled() throws -> Bool        { throw notImplemented("biometricIsEnrolled") }
    public func getLogs(bundleId: String?, lines: Int) throws -> String { throw notImplemented("getLogs") }
    public func setPermission(action: String, service: String, bundleId: String) throws { throw notImplemented("setPermission") }
    public func rotate(direction: String) throws            { throw notImplemented("rotate") }
    public func drag(from: String, to: String, duration: Double) throws { throw notImplemented("drag") }
    public func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws { throw notImplemented("dragCoordinates") }
    public func pressKey(key: String) throws                { throw notImplemented("pressKey") }
    public func hideKeyboard() throws {
        _ = try sendCommand("hideKeyboard")
    }
    public func eraseText(count: Int) throws                { throw notImplemented("eraseText") }
    public func copyTextFrom(target: String) throws -> String { throw notImplemented("copyTextFrom") }
    public func clearState(bundleId: String) throws         { throw notImplemented("clearState") }
    public func uninstallApp(bundleId: String) throws       { throw notImplemented("uninstallApp") }
    public func scrollTo(target: String, direction: String, maxAttempts: Int) throws { throw notImplemented("scrollTo") }
    public func startRecording() throws                     { throw notImplemented("startRecording") }
    public func stopRecording(outputPath: String) throws    { throw notImplemented("stopRecording") }
    public func setLocation(latitude: Double, longitude: Double) throws { throw notImplemented("setLocation") }
    public func setAppearance(mode: String) throws          { throw notImplemented("setAppearance") }
    public func lockDevice() throws                         { throw notImplemented("lockDevice") }
    public func unlockDevice() throws                       { throw notImplemented("unlockDevice") }
    public func pushFile(localPath: String, remotePath: String) throws { throw notImplemented("pushFile") }
    public func pullFile(remotePath: String, localPath: String) throws { throw notImplemented("pullFile") }

    // MARK: - Helpers

    private func notImplemented(_ method: String) -> BridgeError {
        .unknown("not implemented in XCUI bridge: \(method)")
    }

    /// Open a TCP socket to (host, port). Returns fd or nil on any failure.
    /// Fast-fails (100ms) if the runner isn't up, so the fallback path engages quickly.
    private func connectTCP(host: String, port: UInt16) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var tv = timeval(tv_sec: 0, tv_usec: 100_000) // 100ms
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            close(fd)
            return nil
        }

        // After successful connect, set a longer receive timeout for data exchange
        var rxTv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rxTv, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// Connect to autopilotd's Unix socket, auto-detecting the UDID.
    /// Returns fd or nil on failure.
    private func connectDaemonUnixSocket() -> Int32? {
        guard let udid = detectBootedUDID() else { return nil }
        let path = "/tmp/autopilot-\(sanitizeUDID(udid)).sock"
        return connectUnixSocket(path: path)
    }

    private func sanitizeUDID(_ udid: String) -> String {
        String(udid.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
    }

    private func detectBootedUDID() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = ["simctl", "list", "devices", "booted", "-j"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: [[String: Any]]] else { return nil }

        for (_, list) in devices {
            for d in list where (d["state"] as? String) == "Booted" {
                if let u = d["udid"] as? String { return u }
            }
        }
        return nil
    }

    private func connectUnixSocket(path: String) -> Int32? {
        let maxPathLen = 104
        guard path.utf8.count < maxPathLen else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        // Long read timeout — the daemon may trigger a cold boot (~45s)
        var tv = timeval(tv_sec: 90, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                _ = strncpy(dst, src, maxPathLen - 1)
                dst.advanced(by: maxPathLen - 1).pointee = 0
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(fd)
            return nil
        }
        return fd
    }
}
