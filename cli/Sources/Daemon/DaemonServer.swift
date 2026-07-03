import Foundation
import AutoCore

// MARK: - DaemonServer
//
// Unix socket server that accepts JSON line commands and dispatches them.
// Manages an idle timer that shuts down the runner after a configurable timeout
// while keeping the daemon alive for fast re-boot.

final class DaemonServer {
    let udid: String
    let idleTimeout: TimeInterval
    let runner: RunnerLifecycle

    private var serverFD: Int32 = -1
    private var lastActivity = Date()
    private var shouldQuit = false

    init(udid: String, idleTimeout: TimeInterval) {
        self.udid = udid
        self.idleTimeout = idleTimeout
        self.runner = RunnerLifecycle(udid: udid)
    }

    /// Main run loop — blocks until quit command or signal.
    func run() {
        let socketPath = DaemonPaths.socketFile(udid: udid)

        do {
            serverFD = try UnixSocket.listen(at: socketPath)
        } catch {
            fputs("error: failed to start socket server: \(error.localizedDescription)\n", stderr)
            return
        }

        defer {
            close(serverFD)
            unlink(socketPath)
        }

        // Idle timer: checks every 30s if runner should be shut down
        let timerSource = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timerSource.schedule(deadline: .now() + 30, repeating: 30)
        timerSource.setEventHandler { [weak self] in
            self?.checkIdleTimeout()
        }
        timerSource.resume()

        // Accept loop on background queue, dispatch on main for runner ops
        let acceptQueue = DispatchQueue(label: "autopilotd.accept")
        acceptQueue.async { [weak self] in
            self?.acceptLoop()
        }

        // Block main thread on RunLoop (signal handlers installed on main)
        while !shouldQuit {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.5))
        }

        timerSource.cancel()
        runner.shutdownRunner()
    }

    // MARK: - Accept loop

    private func acceptLoop() {
        while !shouldQuit {
            var clientAddr = sockaddr()
            var clientLen = socklen_t(MemoryLayout<sockaddr>.size)
            let clientFD = Darwin.accept(serverFD, &clientAddr, &clientLen)
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }

            handleClient(clientFD)
            close(clientFD)
        }
    }

    private func handleClient(_ fd: Int32) {
        // Read lines until client disconnects
        var buffer = Data()
        var readBuf = [UInt8](repeating: 0, count: 65536)

        while true {
            let n = recv(fd, &readBuf, readBuf.count, 0)
            if n <= 0 { break }

            buffer.append(readBuf, count: n)

            // Process complete lines
            while let newlineIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[buffer.startIndex..<newlineIdx]
                buffer = Data(buffer[buffer.index(after: newlineIdx)...])

                let line = String(data: lineData, encoding: .utf8) ?? ""
                let response = handleCommand(line.trimmingCharacters(in: .whitespacesAndNewlines))

                let responseBytes = (response + "\n").data(using: .utf8) ?? Data()
                responseBytes.withUnsafeBytes { ptr in
                    _ = send(fd, ptr.baseAddress!, responseBytes.count, 0)
                }

                if line.contains("\"quit\"") {
                    shouldQuit = true
                    return
                }
            }
        }
    }

    // MARK: - Command dispatch

    private func handleCommand(_ line: String) -> String {
        lastActivity = Date()

        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let method = json["method"] as? String else {
            return errorResponse("invalid JSON or missing 'method'")
        }

        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "ping":
            return successResponse(["result": "pong"])

        case "status":
            let runnerState = runner.state.rawValue
            let idle = Int(Date().timeIntervalSince(lastActivity))
            return successResponse([
                "runner": runnerState,
                "idle_seconds": idle,
                "timeout": Int(idleTimeout),
                "udid": udid
            ])

        case "boot":
            return handleBoot(params: params)

        case "shutdown_runner":
            runner.shutdownRunner()
            return successResponse(["result": "runner shutdown"])

        case "quit":
            return successResponse(["result": "bye"])

        default:
            // Forward to the runner if it's alive
            return forwardToRunner(method: method, params: params)
        }
    }

    private func handleBoot(params: [String: Any]) -> String {
        let runnerPath = params["runner_path"] as? String
        do {
            try runner.bootIfNeeded(runnerPath: runnerPath)
            return successResponse(["result": "runner booted", "state": runner.state.rawValue])
        } catch {
            return errorResponse("boot failed: \(error.localizedDescription)")
        }
    }

    private func forwardToRunner(method: String, params: [String: Any]) -> String {
        guard runner.state == .ready, let port = runner.runnerPort else {
            // Auto-boot the runner on first real command
            do {
                try runner.bootIfNeeded(runnerPath: nil)
                // Wait for ready
                for _ in 0..<50 {
                    if runner.state == .ready { break }
                    usleep(200_000)
                }
                guard runner.state == .ready, let port = runner.runnerPort else {
                    return errorResponse("runner not ready after boot (state=\(runner.state.rawValue))")
                }
                return sendToRunner(port: port, method: method, params: params)
            } catch {
                return errorResponse("auto-boot failed: \(error.localizedDescription)")
            }
        }

        return sendToRunner(port: port, method: method, params: params)
    }

    private func sendToRunner(port: UInt16, method: String, params: [String: Any]) -> String {
        // TCP connect to runner inside the simulator (127.0.0.1:<port>)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return errorResponse("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            return errorResponse("cannot connect to runner at 127.0.0.1:\(port)")
        }

        // #156: sin SO_RCVTIMEO un runner zombie dejaba este recv() bloqueado
        // para siempre y, como el accept loop es secuencial, ningun cliente
        // futuro podia conectar (wedge permanente de autopilotd hasta kill
        // manual). 60s cubre el primer comando tras cold boot (~45s).
        SocketTimeouts.applyReceiveTimeout(fd: fd, seconds: SocketTimeouts.runnerReceiveSeconds)

        // Build and send request
        var request: [String: Any] = ["method": method]
        if !params.isEmpty { request["params"] = params }

        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              var requestStr = String(data: requestData, encoding: .utf8) else {
            return errorResponse("failed to encode request")
        }
        requestStr += "\n"

        _ = requestStr.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

        // Read response
        var responseBuf = [UInt8](repeating: 0, count: 65536)
        var responseData = Data()

        readLoop: while true {
            let n = recv(fd, &responseBuf, responseBuf.count, 0)
            switch SocketReadOutcome.classify(bytesRead: n, errnoValue: errno) {
            case .data(let count):
                for i in 0..<count {
                    if responseBuf[i] == 0x0A {
                        responseData.append(responseBuf, count: i)
                        return String(data: responseData, encoding: .utf8) ?? errorResponse("decode failed")
                    }
                }
                responseData.append(responseBuf, count: count)
            case .interrupted:
                continue
            case .timedOut:
                // Runner colgado (#156): responder error al cliente y marcar
                // el runner muerto para que el siguiente request lo relance
                // via el auto-boot de forwardToRunner.
                fputs("autopilotd: runner timed out after \(SocketTimeouts.runnerReceiveSeconds)s (method: \(method)) — shutting it down\n", stderr)
                runner.shutdownRunner()
                return errorResponse(
                    "runner did not respond within \(SocketTimeouts.runnerReceiveSeconds)s (method: \(method)); " +
                    "runner marked dead — retry the command to relaunch it"
                )
            case .closed, .failed:
                break readLoop // el chequeo de respuesta vacia decide abajo
            }
        }

        if responseData.isEmpty {
            return errorResponse("empty response from runner")
        }
        return String(data: responseData, encoding: .utf8) ?? errorResponse("decode failed")
    }

    // MARK: - Idle timeout

    private func checkIdleTimeout() {
        // idleTimeout == 0 means "never shut down runner on idle" — runner stays
        // alive as long as the daemon is up. Cold boot is only paid once per
        // daemon session. This is the default for interactive use.
        if idleTimeout <= 0 { return }

        let idle = Date().timeIntervalSince(lastActivity)
        if idle >= idleTimeout && runner.state == .ready {
            fputs("autopilotd: runner idle for \(Int(idle))s, shutting down runner\n", stderr)
            runner.shutdownRunner()
        }
    }

    // MARK: - JSON helpers

    private func successResponse(_ dict: [String: Any]) -> String {
        let wrapped: [String: Any] = ["ok": true, "result": dict]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapped),
              let str = String(data: data, encoding: .utf8) else {
            return #"{"ok":true,"result":{}}"#
        }
        return str
    }

    private func errorResponse(_ message: String) -> String {
        let escaped = message.replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"ok\":false,\"error\":\"\(escaped)\"}"
    }
}
