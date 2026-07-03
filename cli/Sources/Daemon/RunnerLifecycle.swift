import Foundation
import AutoCore

// MARK: - RunnerLifecycle
//
// Manages the XCTest runner process lifecycle:
//   - Boot: launches xcodebuild test-without-building in background
//   - Probe: checks if the runner's TCP server is responding
//   - Shutdown: kills the xcodebuild process gracefully

final class RunnerLifecycle {
    let udid: String

    /// TCP port the runner listens on inside the simulator (loopback).
    /// Matches the port in the XCTest runner's server (spike: 22087).
    static let defaultRunnerPort: UInt16 = 22087

    private(set) var state: RunnerState = .notBooted
    private(set) var runnerPort: UInt16?
    private var xcodebuildProcess: Process?
    private let queue = DispatchQueue(label: "autopilotd.runner")

    init(udid: String) {
        self.udid = udid
    }

    // MARK: - Boot

    /// Boot the runner if not already alive. Idempotent.
    func bootIfNeeded(runnerPath: String? = nil) throws {
        if state == .ready, probeRunner() { return }
        if state == .booting { return }

        state = .booting

        let envOverride = ProcessInfo.processInfo.environment["AUTOPILOT_RUNNER_XCTESTRUN"]
        let xctestRunPath: String
        if let override = envOverride, !override.isEmpty {
            // Override via env var — validate file exists + extension
            guard override.hasSuffix(".xctestrun"),
                  FileManager.default.fileExists(atPath: override) else {
                state = .notBooted
                throw BootError.xctestRunNotFound(override)
            }
            xctestRunPath = override
        } else if let path = runnerPath {
            xctestRunPath = path
        } else {
            // Default: look in ~/.autopilot/runner/ for .xctestrun
            let home = NSHomeDirectory()
            let runnerDir = "\(home)/.autopilot/runner"
            let candidates = (try? FileManager.default.contentsOfDirectory(atPath: runnerDir))?
                .filter { $0.hasSuffix(".xctestrun") } ?? []
            guard let first = candidates.first else {
                state = .notBooted
                throw BootError.noRunnerFound(runnerDir)
            }
            xctestRunPath = "\(runnerDir)/\(first)"
        }

        guard FileManager.default.fileExists(atPath: xctestRunPath) else {
            state = .notBooted
            throw BootError.xctestRunNotFound(xctestRunPath)
        }

        // Launch xcodebuild test-without-building in background.
        // Test identifier can be overridden via env var for E2E against demo runner.
        let env = ProcessInfo.processInfo.environment
        let testID = env["AUTOPILOT_RUNNER_TEST_ID"]
            ?? "AutoPilotRunnerUITests/AutoPilotRunnerTests/testServe"

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        proc.arguments = [
            "xcodebuild", "test-without-building",
            "-xctestrun", xctestRunPath,
            "-destination", "platform=iOS Simulator,id=\(udid)",
            "-only-testing:\(testID)",
            // Xcode 26 defaults to cloning the simulator for tests. When the test
            // ends, the clone is destroyed — which also ends up terminating the
            // parent simulator. Disable parallel testing and clone destinations.
            "-parallel-testing-enabled", "NO",
            "-disable-concurrent-destination-testing",
            "-maximum-concurrent-test-simulator-destinations", "1"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.state = .notBooted }
        }

        do {
            try proc.run()
        } catch {
            state = .notBooted
            throw BootError.launchFailed(error.localizedDescription)
        }

        xcodebuildProcess = proc

        // Wait for the runner's TCP server to become responsive (up to 60s)
        // xcodebuild cold boot + simctl install + app launch typically takes 30-45s
        let port = Self.defaultRunnerPort
        var ready = false
        for _ in 0..<300 {
            usleep(200_000)
            if probeRunnerPort(port) {
                ready = true
                break
            }
        }

        if ready {
            runnerPort = port
            state = .ready
            fputs("autopilotd: runner ready on 127.0.0.1:\(port)\n", stderr)
        } else {
            // Runner didn't respond — kill and mark failed
            shutdownRunner()
            throw BootError.runnerNotResponding(port)
        }
    }

    // MARK: - Shutdown

    func shutdownRunner() {
        guard let proc = xcodebuildProcess, proc.isRunning else {
            state = .notBooted
            xcodebuildProcess = nil
            runnerPort = nil
            return
        }

        state = .shuttingDown

        // Try graceful shutdown: send quit to runner
        if let port = runnerPort {
            sendQuitToRunner(port: port)
        }

        // SIGTERM to xcodebuild
        proc.terminate()

        // Wait up to 5s for exit
        let deadline = Date().addingTimeInterval(5)
        while proc.isRunning && Date() < deadline {
            usleep(100_000)
        }

        // Force kill if still alive
        if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
        }

        xcodebuildProcess = nil
        runnerPort = nil
        state = .notBooted
        fputs("autopilotd: runner shut down\n", stderr)
    }

    // MARK: - Probe

    func probeRunner() -> Bool {
        guard let port = runnerPort else { return false }
        return probeRunnerPort(port)
    }

    private func probeRunnerPort(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        // 1s receive timeout for probe
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else { return false }

        // Send ping
        let msg = "{\"method\":\"ping\"}\n"
        _ = msg.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

        // Read response
        var buf = [UInt8](repeating: 0, count: 1024)
        let n = recv(fd, &buf, buf.count, 0)
        return n > 0
    }

    private func sendQuitToRunner(port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { return }

        // #156: sin timeout, un runner zombie que acepta la conexion pero
        // nunca responde el ack dejaba shutdownRunner() colgado — justo el
        // path que se ejecuta al detectar un runner que no responde.
        SocketTimeouts.applyReceiveTimeout(fd: fd, seconds: 2)

        let msg = "{\"method\":\"quit\"}\n"
        _ = msg.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

        // Read ack (best effort)
        var buf = [UInt8](repeating: 0, count: 256)
        _ = recv(fd, &buf, buf.count, 0)
    }
}

// MARK: - Types

enum RunnerState: String {
    case notBooted = "not_booted"
    case booting = "booting"
    case ready = "ready"
    case shuttingDown = "shutting_down"
}

enum BootError: Error, LocalizedError {
    case noRunnerFound(String)
    case xctestRunNotFound(String)
    case launchFailed(String)
    case runnerNotResponding(UInt16)

    var errorDescription: String? {
        switch self {
        case .noRunnerFound(let dir): return "no .xctestrun found in \(dir)"
        case .xctestRunNotFound(let path): return ".xctestrun not found at \(path)"
        case .launchFailed(let msg): return "xcodebuild launch failed: \(msg)"
        case .runnerNotResponding(let port): return "runner not responding on 127.0.0.1:\(port) after 15s"
        }
    }
}
