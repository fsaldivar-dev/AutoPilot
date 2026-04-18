import Foundation

/// Registro de backends indexado por ActionKind.
/// Thread-safe via actor — registrar y consultar desde cualquier contexto async.
public actor CapabilityRegistry {
    private var backends: [any Backend] = []
    private var index: [ActionKind: [any Backend]] = [:]

    public init() {}

    /// Registra un backend y lo indexa por sus capabilities declaradas.
    /// El orden de registro determina la prioridad en el escalation del router.
    public func register(_ backend: any Backend) {
        backends.append(backend)
        for kind in backend.capabilities {
            index[kind, default: []].append(backend)
        }
    }

    /// Retorna todos los backends capaces de ejecutar el ActionKind dado,
    /// en el orden en que fueron registrados.
    public func capable(of kind: ActionKind) -> [any Backend] {
        index[kind] ?? []
    }

    /// Retorna todos los backends registrados.
    public func allBackends() -> [any Backend] {
        backends
    }
}
