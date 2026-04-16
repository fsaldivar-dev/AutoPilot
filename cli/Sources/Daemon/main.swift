import Foundation
import AutoCore

// MARK: - autopilotd — sidecar daemon for XCTest runner lifecycle
//
// Usage:
//   autopilotd start [--udid <UDID>] [--timeout <seconds>]
//   autopilotd stop  [--udid <UDID>]
//   autopilotd status [--udid <UDID>]
//
// The daemon manages an XCTest runner process inside an iOS simulator,
// exposing a Unix socket for the CLI to send commands to the runner.
// When idle for --timeout seconds (default 120), the runner is shut down
// but the daemon stays alive for fast re-boot on next command.

let args = CommandLine.arguments
guard args.count >= 2 else {
    printUsage()
    exit(1)
}

let subcommand = args[1]
let udid = parseFlag("--udid", from: args) ?? autoDetectBootedUDID()
let timeout = Double(parseFlag("--timeout", from: args) ?? "120") ?? 120

guard let udid = udid else {
    fputs("error: no --udid provided and no booted simulator found\n", stderr)
    exit(1)
}

switch subcommand {
case "start":
    startDaemon(udid: udid, timeout: timeout)
case "stop":
    stopDaemon(udid: udid)
case "status":
    printStatus(udid: udid)
default:
    printUsage()
    exit(1)
}

// MARK: - Subcommands

func startDaemon(udid: String, timeout: Double) {
    let pidPath = DaemonPaths.pidFile(udid: udid)
    let socketPath = DaemonPaths.socketFile(udid: udid)

    // Check if already running
    if let existingPID = readPID(pidPath), isProcessAlive(existingPID) {
        print("daemon already running (pid=\(existingPID), socket=\(socketPath))")
        exit(0)
    }

    // Clean stale files
    try? FileManager.default.removeItem(atPath: pidPath)
    try? FileManager.default.removeItem(atPath: socketPath)

    // Write our PID
    let pid = ProcessInfo.processInfo.processIdentifier
    try? String(pid).write(toFile: pidPath, atomically: true, encoding: .utf8)

    // Install signal handlers for graceful shutdown
    let sigSources = installSignalHandlers(udid: udid)

    print("autopilotd started (pid=\(pid), udid=\(udid), timeout=\(Int(timeout))s)")
    print("socket: \(socketPath)")

    // Start the server (blocks until quit/signal)
    let server = DaemonServer(udid: udid, idleTimeout: timeout)
    server.run()

    // Cleanup
    for src in sigSources { src.cancel() }
    cleanup(udid: udid)
}

func stopDaemon(udid: String) {
    let pidPath = DaemonPaths.pidFile(udid: udid)
    guard let pid = readPID(pidPath) else {
        print("no daemon running for udid=\(udid)")
        return
    }

    kill(pid, SIGTERM)

    // Wait up to 5s for graceful exit
    for _ in 0..<50 {
        if !isProcessAlive(pid) {
            print("daemon stopped (pid=\(pid))")
            cleanup(udid: udid)
            return
        }
        usleep(100_000)
    }

    // Force kill
    kill(pid, SIGKILL)
    cleanup(udid: udid)
    print("daemon killed (pid=\(pid))")
}

func printStatus(udid: String) {
    let pidPath = DaemonPaths.pidFile(udid: udid)
    let socketPath = DaemonPaths.socketFile(udid: udid)

    guard let pid = readPID(pidPath), isProcessAlive(pid) else {
        print("daemon: not running")
        return
    }

    let socketExists = FileManager.default.fileExists(atPath: socketPath)
    print("daemon: running (pid=\(pid))")
    print("socket: \(socketExists ? socketPath : "missing")")

    // Probe daemon for status via socket
    if socketExists {
        if let response = probeDaemon(socketPath: socketPath, method: "status") {
            print("runner: \(response)")
        } else {
            print("runner: unknown (socket probe failed)")
        }
    }
}

// MARK: - Helpers

func printUsage() {
    fputs("""
    Usage: autopilotd <start|stop|status> [--udid <UDID>] [--timeout <seconds>]

    Manages the XCTest runner sidecar for iOS simulator automation.
    If --udid is omitted, uses the first booted simulator.
    Default idle timeout: 120 seconds.

    """, stderr)
}

func parseFlag(_ flag: String, from args: [String]) -> String? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return args[idx + 1]
}

func autoDetectBootedUDID() -> String? {
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

    for (_, deviceList) in devices {
        for device in deviceList {
            if let state = device["state"] as? String, state == "Booted",
               let udid = device["udid"] as? String {
                return udid
            }
        }
    }
    return nil
}

func readPID(_ path: String) -> pid_t? {
    guard let str = try? String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
          let pid = Int32(str) else { return nil }
    return pid
}

func isProcessAlive(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0
}

func cleanup(udid: String) {
    try? FileManager.default.removeItem(atPath: DaemonPaths.pidFile(udid: udid))
    try? FileManager.default.removeItem(atPath: DaemonPaths.socketFile(udid: udid))
}

func installSignalHandlers(udid: String) -> [DispatchSourceSignal] {
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGTERM, SIGINT, SIGHUP] {
        signal(sig, SIG_IGN) // Ignore default handling
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler {
            cleanup(udid: udid)
            exit(0)
        }
        src.resume()
        sources.append(src)
    }
    return sources
}

func probeDaemon(socketPath: String, method: String) -> String? {
    guard let fd = UnixSocket.connect(to: socketPath) else { return nil }
    defer { close(fd) }

    let msg = "{\"method\":\"\(method)\"}\n"
    _ = msg.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }

    var buf = [UInt8](repeating: 0, count: 4096)
    let n = recv(fd, &buf, buf.count, 0)
    guard n > 0 else { return nil }

    return String(bytes: buf[0..<n], encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Paths

enum DaemonPaths {
    static let maxSunPathLen = 104 // macOS sockaddr_un.sun_path size

    static func sanitizedUDID(_ udid: String) -> String {
        // Only allow alphanumeric + hyphen to prevent path injection
        String(udid.filter { $0.isLetter || $0.isNumber || $0 == "-" }.prefix(40))
    }

    static func pidFile(udid: String) -> String {
        "/tmp/autopilot-\(sanitizedUDID(udid)).pid"
    }

    static func socketFile(udid: String) -> String {
        let path = "/tmp/autopilot-\(sanitizedUDID(udid)).sock"
        precondition(path.utf8.count < maxSunPathLen, "socket path exceeds sun_path limit")
        return path
    }
}

// MARK: - Unix socket helpers (safe, bounds-checked)

enum UnixSocket {
    /// Create a Unix domain socket bound and listening at `path`.
    static func listen(at path: String, backlog: Int32 = 4) throws -> Int32 {
        guard path.utf8.count < DaemonPaths.maxSunPathLen else {
            throw NSError(domain: "UnixSocket", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "socket path too long (\(path.utf8.count) >= \(DaemonPaths.maxSunPathLen))"])
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw NSError(domain: "UnixSocket", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "socket() failed: \(errno)"])
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Safe copy with bounds check via strncpy + explicit NUL
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                _ = strncpy(dst, src, DaemonPaths.maxSunPathLen - 1)
                dst.advanced(by: DaemonPaths.maxSunPathLen - 1).pointee = 0
            }
        }

        // Remove stale socket file
        unlink(path)

        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            close(fd)
            throw NSError(domain: "UnixSocket", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "bind() failed: \(errno)"])
        }

        guard Darwin.listen(fd, backlog) == 0 else {
            close(fd)
            throw NSError(domain: "UnixSocket", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "listen() failed: \(errno)"])
        }

        return fd
    }

    /// Connect to a Unix domain socket at `path`. Returns fd or nil.
    static func connect(to path: String) -> Int32? {
        guard path.utf8.count < DaemonPaths.maxSunPathLen else { return nil }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path.0) { dst in
                _ = strncpy(dst, src, DaemonPaths.maxSunPathLen - 1)
                dst.advanced(by: DaemonPaths.maxSunPathLen - 1).pointee = 0
            }
        }

        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard result == 0 else {
            close(fd)
            return nil
        }

        return fd
    }
}
