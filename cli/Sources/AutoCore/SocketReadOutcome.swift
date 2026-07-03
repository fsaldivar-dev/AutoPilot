import Foundation

// MARK: - SocketReadOutcome (#156)
//
// Sin `SO_RCVTIMEO`, un `recv()` bloqueante sobre un peer colgado (proceso
// vivo que nunca responde) congela al proceso para siempre: CLI, sidecar del
// editor o autopilotd completo. La clasificacion del retorno de `recv()` +
// `errno` vive aqui como funcion pura para poder testearla sin sockets reales.

/// Resultado clasificado de una llamada a `recv()`.
public enum SocketReadOutcome: Equatable {
    /// Llegaron `bytesRead` bytes (> 0).
    case data(Int)
    /// El peer cerro la conexion de forma ordenada (`recv` devolvio 0).
    case closed
    /// Expiro `SO_RCVTIMEO` sin datos (EAGAIN/EWOULDBLOCK) o el kernel
    /// reporto timeout de transporte (ETIMEDOUT). El peer sigue "conectado"
    /// pero no responde — tratarlo como colgado.
    case timedOut
    /// `recv` fue interrumpido por una senal (EINTR) — reintentar la lectura.
    case interrupted
    /// Cualquier otro fallo de socket (ECONNRESET, EBADF, ...).
    case failed(errno: Int32)

    /// Funcion pura: mapea el retorno de `recv()` y el `errno` vigente.
    /// Nota: `errno` solo es significativo cuando `bytesRead < 0`.
    public static func classify(bytesRead: Int, errnoValue: Int32) -> SocketReadOutcome {
        if bytesRead > 0 { return .data(bytesRead) }
        if bytesRead == 0 { return .closed }
        switch errnoValue {
        case EAGAIN, EWOULDBLOCK, ETIMEDOUT:
            return .timedOut
        case EINTR:
            return .interrupted
        default:
            return .failed(errno: errnoValue)
        }
    }
}

/// Timeouts de lectura de los sockets del proyecto (#156).
public enum SocketTimeouts {
    /// Agente Android (AgentBridge): sus comandos tardan de milisegundos a
    /// pocos segundos (tree es la operacion mas cara). 15s separa "lento"
    /// de "colgado" con margen amplio y sigue siendo tolerable como espera
    /// maxima antes de disparar el recovery automatico.
    public static let agentReceiveSeconds = 15

    /// Runner XCTest (autopilotd → runner): 60s cubre el primer comando tras
    /// cold boot (el attach inicial de XCUIApplication puede tardar ~45s) y
    /// `tree deep` (~13s), sin dejar al daemon en wedge permanente.
    public static let runnerReceiveSeconds = 60

    /// Aplica `SO_RCVTIMEO` al fd. Devuelve false si setsockopt fallo.
    @discardableResult
    public static func applyReceiveTimeout(fd: Int32, seconds: Int) -> Bool {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv,
                          socklen_t(MemoryLayout<timeval>.size)) == 0
    }
}
