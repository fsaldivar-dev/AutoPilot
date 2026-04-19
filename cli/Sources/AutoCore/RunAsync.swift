import Foundation

/// Ejecuta un bloque `async throws` bloqueando el hilo actual. Diseñado para
/// puentear el `main.swift` síncrono con los helpers que usan `ActionRouter`
/// (actor → async). El bloque propaga errores como si fuera sync.
///
/// Preferible a repetir el patrón DispatchGroup+Task+leave en cada callsite.
public func runAsync(_ block: @escaping @Sendable () async throws -> Void) {
    let group = DispatchGroup()
    group.enter()
    let thrown = ErrorBox()
    Task {
        do {
            try await block()
        } catch {
            thrown.error = error
        }
        group.leave()
    }
    group.wait()
    if let e = thrown.error {
        print("Error: \(e)")
        exit(1)
    }
}

/// Variante que retorna un valor `Sendable` del bloque async.
/// Útil para `case` que necesitan decidir fall-through en base al resultado.
public func runAsyncReturning<T: Sendable>(_ block: @escaping @Sendable () async throws -> T) -> T {
    let group = DispatchGroup()
    group.enter()
    let box = ResultBox<T>()
    Task {
        do {
            box.value = try await block()
        } catch {
            box.error = error
        }
        group.leave()
    }
    group.wait()
    if let e = box.error {
        print("Error: \(e)")
        exit(1)
    }
    guard let v = box.value else {
        print("Error: runAsyncReturning produced no value")
        exit(1)
    }
    return v
}

/// Scratchpad thread-safe para propagar resultados/errores de un Task al
/// hilo principal que está esperando en DispatchGroup.
final class ErrorBox: @unchecked Sendable {
    var error: Error?
}

final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: T?
    var error: Error?
}
