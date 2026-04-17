import Foundation
import XCTest

// MARK: - RunnerServer
//
// TCP loopback server that runs inside the XCTest runner process.
// Receives JSON commands from autopilotd (via port forwarding or direct
// loopback on the simulator), dispatches them to XCUIApplication, and
// returns JSON responses.
//
// Protocol: JSON line per request/response, terminated by \n (0x0A).
// Request:  {"method":"tap","params":{"target":"Login"}}
// Response: {"ok":true,"result":{...}}\n  or  {"ok":false,"error":"..."}\n

final class RunnerServer {
    let port: UInt16
    let app: XCUIApplication
    private var serverFD: Int32 = -1
    private var shouldStop = false
    private lazy var handlers = RunnerHandlers(app: app)

    init(port: UInt16 = 22087, app: XCUIApplication) {
        self.port = port
        self.app = app
    }

    /// Start the TCP server. Blocks the calling thread until quit is received.
    func start() throws {
        serverFD = try createLoopbackServer(port: port)
        defer { Darwin.close(serverFD) }

        NSLog("AutoPilotRunner: server listening on 127.0.0.1:\(port)")

        while !shouldStop {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = Darwin.accept(serverFD, &clientAddr, &clientLen)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            handleClient(clientFD)
            Darwin.close(clientFD)
        }

        NSLog("AutoPilotRunner: server stopped")
    }

    // MARK: - Client handling

    private func handleClient(_ fd: Int32) {
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 65536)

        while !shouldStop {
            let n = Darwin.read(fd, &readBuf, readBuf.count)
            if n <= 0 { break }

            buffer.append(readBuf, count: n)

            // Process complete lines
            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIdx]
                buffer = Data(buffer[buffer.index(after: newlineIdx)...])

                let line = String(data: lineData, encoding: .utf8) ?? ""
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

                let response = dispatch(trimmed)

                let responseBytes = (response + "\n").data(using: .utf8) ?? Data()
                responseBytes.withUnsafeBytes { ptr in
                    _ = Darwin.write(fd, ptr.baseAddress!, responseBytes.count)
                }

                if trimmed.contains("\"quit\"") {
                    shouldStop = true
                    return
                }
            }
        }
    }

    // MARK: - Command dispatch

    private func dispatch(_ line: String) -> String {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return errorJSON("invalid JSON or missing 'method'")
        }

        let params = json["params"] as? [String: Any] ?? [:]
        let start = CFAbsoluteTimeGetCurrent()

        // ping and quit don't touch XCUIApplication — handle directly
        if method == "ping" {
            return successJSON(["result": "pong"])
        }
        if method == "quit" {
            return successJSON(["result": "bye"])
        }

        // All XCUI operations MUST run on the main thread.
        // Dispatch synchronously and wait for the result.
        let result: String = dispatchOnMain {
            switch method {
            case "tree", "snapshot":
                return self.handlers.handleTree(params: params)
            case "tap":
                return self.handlers.handleTap(params: params)
            case "typeText":
                return self.handlers.handleTypeText(params: params)
            case "waitFor":
                return self.handlers.handleWaitFor(params: params)
            case "screenshot":
                return self.handlers.handleScreenshot(params: params)
            case "launch":
                return self.handlers.handleLaunch(params: params)
            case "terminate":
                return self.handlers.handleTerminate(params: params)
            case "exists":
                return self.handlers.handleExists(params: params)
            case "search":
                return self.handlers.handleSearch(params: params)
            case "list":
                return self.handlers.handleList(params: params)
            case "clear":
                return self.handlers.handleClear(params: params)
            case "longPress":
                return self.handlers.handleLongPress(params: params)
            case "doubleTap":
                return self.handlers.handleDoubleTap(params: params)
            case "scroll":
                return self.handlers.handleScroll(params: params)
            case "swipe":
                return self.handlers.handleSwipe(params: params)
            case "hideKeyboard":
                return self.handlers.handleHideKeyboard()
            default:
                return errorJSON("unknown method: \(method)")
            }
        }

        let elapsed = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)
        NSLog("AutoPilotRunner: \(method) → \(elapsed)ms")

        return result
    }

    /// Execute a block on the main thread synchronously and return its result.
    /// Required because XCUIApplication APIs must be called from the main thread.
    private func dispatchOnMain(_ block: @escaping () -> String) -> String {
        if Thread.isMainThread {
            return block()
        }

        var result = ""
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            result = block()
            semaphore.signal()
        }
        semaphore.wait()
        return result
    }

    // MARK: - TCP server setup

    private func createLoopbackServer(port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw RunnerError.socketFailed("socket() failed: \(errno)")
        }

        var yes: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes,
                              socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0x7f000001).bigEndian // 127.0.0.1

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult >= 0 else {
            Darwin.close(fd)
            throw RunnerError.socketFailed("bind() failed: \(errno)")
        }

        guard Darwin.listen(fd, 4) >= 0 else {
            Darwin.close(fd)
            throw RunnerError.socketFailed("listen() failed: \(errno)")
        }

        return fd
    }
}

// MARK: - JSON helpers

func successJSON(_ dict: [String: Any]) -> String {
    let wrapped: [String: Any] = ["ok": true, "result": dict]
    guard let data = try? JSONSerialization.data(withJSONObject: wrapped),
          let str = String(data: data, encoding: .utf8) else {
        return #"{"ok":true,"result":{}}"#
    }
    return str
}

func errorJSON(_ message: String) -> String {
    let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: " ")
    return "{\"ok\":false,\"error\":\"\(escaped)\"}"
}

// MARK: - Errors

enum RunnerError: Error, LocalizedError {
    case socketFailed(String)
    case elementNotFound(String)

    var errorDescription: String? {
        switch self {
        case .socketFailed(let msg): return msg
        case .elementNotFound(let msg): return msg
        }
    }
}
