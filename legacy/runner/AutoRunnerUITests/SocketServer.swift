import Foundation

/// Unix Domain Socket server that listens for commands.
/// Runs on /tmp/autoapp.sock and accepts JSON messages with length-prefix protocol.
///
/// Protocol: [4 bytes big-endian length][JSON payload]
final class SocketServer {

    private let socketPath: String
    private var serverFD: Int32 = -1
    private var isRunning = false
    private let handler: (Data) -> Data

    init(socketPath: String = "/tmp/autoapp.sock", handler: @escaping (Data) -> Data) {
        self.socketPath = socketPath
        self.handler = handler
    }

    func start() throws {
        // Clean up any existing socket file
        unlink(socketPath)

        // Create socket
        serverFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFD >= 0 else {
            throw SocketError.createFailed(errno: errno)
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw SocketError.pathTooLong
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw SocketError.bindFailed(errno: errno)
        }

        // Listen
        guard listen(serverFD, 5) == 0 else {
            throw SocketError.listenFailed(errno: errno)
        }

        isRunning = true
        print("[AutoApp] Socket server listening on \(socketPath)")

        // Accept loop
        while isRunning {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else {
                if isRunning {
                    print("[AutoApp] Accept failed: \(errno)")
                }
                continue
            }

            print("[AutoApp] Client connected (fd: \(clientFD))")
            handleClient(clientFD)
            close(clientFD)
            print("[AutoApp] Client disconnected (fd: \(clientFD))")
        }
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 {
            close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Client handling

    private func handleClient(_ fd: Int32) {
        while isRunning {
            // Read 4-byte length prefix (big-endian)
            guard let lengthData = readExact(fd: fd, count: 4) else {
                break
            }

            let length = lengthData.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(as: UInt32.self).bigEndian
            }

            guard length > 0, length < 10_000_000 else {
                print("[AutoApp] Invalid message length: \(length)")
                break
            }

            // Read payload
            guard let payload = readExact(fd: fd, count: Int(length)) else {
                break
            }

            // Process command and get response
            let response = handler(payload)

            // Write response with length prefix
            var responseLength = UInt32(response.count).bigEndian
            let lengthBytes = withUnsafeBytes(of: &responseLength) { Data($0) }

            writeAll(fd: fd, data: lengthBytes)
            writeAll(fd: fd, data: response)
        }
    }

    private func readExact(fd: Int32, count: Int) -> Data? {
        var buffer = Data(count: count)
        var totalRead = 0

        while totalRead < count {
            let bytesRead = buffer.withUnsafeMutableBytes { ptr in
                read(fd, ptr.baseAddress!.advanced(by: totalRead), count - totalRead)
            }

            if bytesRead <= 0 {
                return nil
            }
            totalRead += bytesRead
        }

        return buffer
    }

    @discardableResult
    private func writeAll(fd: Int32, data: Data) -> Bool {
        var totalWritten = 0
        let count = data.count

        while totalWritten < count {
            let bytesWritten = data.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!.advanced(by: totalWritten), count - totalWritten)
            }

            if bytesWritten <= 0 {
                return false
            }
            totalWritten += bytesWritten
        }

        return true
    }
}

// MARK: - Errors

enum SocketError: Error, CustomStringConvertible {
    case createFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case pathTooLong

    var description: String {
        switch self {
        case .createFailed(let e): return "Failed to create socket: \(String(cString: strerror(e)))"
        case .bindFailed(let e): return "Failed to bind socket: \(String(cString: strerror(e)))"
        case .listenFailed(let e): return "Failed to listen: \(String(cString: strerror(e)))"
        case .pathTooLong: return "Socket path too long"
        }
    }
}
