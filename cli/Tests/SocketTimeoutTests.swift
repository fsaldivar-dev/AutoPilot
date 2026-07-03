import XCTest
@testable import AutoCore

/// Tests del fix #156 — timeouts de lectura en sockets (AgentBridge y
/// autopilotd → runner). Validan la funcion pura de clasificacion de
/// `recv()` + `errno`, las constantes de timeout y la aplicacion real de
/// `SO_RCVTIMEO`. No requieren emulador, agente ni daemon.
final class SocketTimeoutTests: XCTestCase {

    // MARK: - Clasificacion de recv() + errno (funcion pura)

    func testPositiveBytesIsData() {
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: 42, errnoValue: 0), .data(42))
    }

    func testErrnoIsIgnoredWhenBytesArrive() {
        // errno puede quedar sucio de una syscall anterior — con bytes > 0
        // no debe influir en la clasificacion.
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: 1, errnoValue: EAGAIN), .data(1))
    }

    func testZeroBytesIsOrderlyClose() {
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: 0, errnoValue: 0), .closed)
        // errno tampoco importa cuando el peer cierra ordenadamente.
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: 0, errnoValue: ECONNRESET), .closed)
    }

    func testEagainIsTimeout() {
        // EAGAIN es lo que devuelve recv() al expirar SO_RCVTIMEO en Darwin.
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: -1, errnoValue: EAGAIN), .timedOut)
    }

    func testEwouldblockIsTimeout() {
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: -1, errnoValue: EWOULDBLOCK), .timedOut)
    }

    func testEtimedoutIsTimeout() {
        // Timeout de transporte TCP (keepalive/retransmision agotada).
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: -1, errnoValue: ETIMEDOUT), .timedOut)
    }

    func testEintrIsInterrupted() {
        // Una senal no es un peer muerto — el caller debe reintentar recv().
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: -1, errnoValue: EINTR), .interrupted)
    }

    func testOtherErrnoIsFailure() {
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: -1, errnoValue: ECONNRESET),
                       .failed(errno: ECONNRESET))
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: -1, errnoValue: EBADF),
                       .failed(errno: EBADF))
    }

    // MARK: - Constantes de timeout (#156)

    func testAgentTimeoutSeparatesSlowFromHung() {
        // Los comandos del agente Android tardan de ms a pocos segundos;
        // 15s da margen amplio antes de declarar "colgado" y disparar recovery.
        XCTAssertEqual(SocketTimeouts.agentReceiveSeconds, 15)
    }

    func testRunnerTimeoutCoversColdBoot() {
        // El primer attach de XCUIApplication tras cold boot puede tardar ~45s
        // y `tree deep` ~13s — 60s cubre ambos sin wedge permanente.
        XCTAssertEqual(SocketTimeouts.runnerReceiveSeconds, 60)
        XCTAssertGreaterThan(SocketTimeouts.runnerReceiveSeconds,
                             SocketTimeouts.agentReceiveSeconds)
    }

    // MARK: - applyReceiveTimeout

    func testApplyReceiveTimeoutSetsSockOpt() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }

        XCTAssertTrue(SocketTimeouts.applyReceiveTimeout(fd: fd, seconds: 15))

        // Leer de vuelta la opcion para verificar que quedo aplicada.
        var tv = timeval()
        var len = socklen_t(MemoryLayout<timeval>.size)
        XCTAssertEqual(getsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, &len), 0)
        XCTAssertEqual(tv.tv_sec, 15)
    }

    func testApplyReceiveTimeoutFailsOnBadFD() {
        XCTAssertFalse(SocketTimeouts.applyReceiveTimeout(fd: -1, seconds: 15))
    }

    // MARK: - Integracion minima: recv real sobre peer mudo

    func testRecvOnSilentPeerClassifiesAsTimeout() {
        // Simula el bug exacto de #156 en miniatura: un peer conectado que
        // jamas escribe. Con SO_RCVTIMEO el recv() despierta con EAGAIN y la
        // clasificacion debe ser .timedOut (antes del fix: bloqueo eterno).
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        var tv = timeval(tv_sec: 0, tv_usec: 100_000) // 100ms para no frenar la suite
        setsockopt(fds[0], SOL_SOCKET, SO_RCVTIMEO, &tv,
                   socklen_t(MemoryLayout<timeval>.size))

        var buf = [UInt8](repeating: 0, count: 16)
        let n = recv(fds[0], &buf, buf.count, 0)
        XCTAssertEqual(SocketReadOutcome.classify(bytesRead: n, errnoValue: errno), .timedOut)
    }

    // MARK: - El error tipado que dispara el recovery

    func testBridgeErrorTimeoutCarriesMessage() {
        let err = BridgeError.timeout("Agent did not respond within 15s")
        XCTAssertEqual(err.description, "Agent did not respond within 15s")
    }
}
