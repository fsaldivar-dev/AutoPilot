import Foundation
import UIKit

// Called from Observer.m via @_silgen_name — C-linkage entry point.
@_silgen_name("autopilot_observer_start")
public func autopilotObserverStart() {
    // AX framework activation happens per-RPC (RPCHandler.warmupAccessibility),
    // not here at boot — empirically, boot-time load causes the observer
    // listener to go silent on device.
    let defaultPort = 7002
    let port: Int
    if let raw = ProcessInfo.processInfo.environment["AUTOPILOT_OBSERVER_PORT"],
       let parsed = Int(raw), (1...65535).contains(parsed) {
        port = parsed
    } else {
        port = defaultPort
    }
    IPCServer.shared.start(port: port)
}

final class IPCServer {
    static let shared = IPCServer()
    private var serverFD: Int32 = -1
    private let queue = DispatchQueue(label: "dev.autopilot.observer.ipc", attributes: .concurrent)

    func start(port: Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("[AutoPilotObserver] socket() failed errno=\(errno)")
            return
        }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            NSLog("[AutoPilotObserver] bind(127.0.0.1:\(port)) failed errno=\(errno)")
            close(fd); return
        }
        guard listen(fd, 8) == 0 else {
            NSLog("[AutoPilotObserver] listen() failed errno=\(errno)")
            close(fd); return
        }

        serverFD = fd
        queue.async { self.acceptLoop(serverFD: fd) }
    }

    private func acceptLoop(serverFD: Int32) {
        while true {
            let clientFD = accept(serverFD, nil, nil)
            guard clientFD >= 0 else { break }
            queue.async { self.handleClient(fd: clientFD) }
        }
    }

    private func handleClient(fd: Int32) {
        defer { close(fd) }
        let handler = RPCHandler()

        var buf = Data()
        let tmp = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { tmp.deallocate() }

        while true {
            let n = recv(fd, tmp, 4096, 0)
            if n <= 0 { break }
            buf.append(tmp, count: n)

            while let nl = buf.firstIndex(of: 0x0A) {
                let lineData = buf[buf.startIndex..<nl]
                buf = Data(buf[buf.index(after: nl)...])

                guard let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else { continue }
                let response = handler.handle(json)
                guard let responseData = try? JSONSerialization.data(withJSONObject: response),
                      var responseStr = String(data: responseData, encoding: .utf8) else { continue }
                responseStr += "\n"
                _ = responseStr.withCString { ptr in send(fd, ptr, strlen(ptr), 0) }
            }
        }
    }
}
