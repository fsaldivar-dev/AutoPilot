import Foundation

// MARK: - Error

public enum ActionRouterError: Error, CustomStringConvertible {
    case noBackendForAction(ActionKind)

    public var description: String {
        switch self {
        case .noBackendForAction(let kind):
            return "No backend registered for action: \(kind)"
        }
    }
}

// MARK: - ActionRouter

/// Punto único de ejecución de acciones. Consulta el registry y escala
/// automáticamente al siguiente backend si el primero lanza elementNotFound.
///
/// Escalation: secuencial en el orden de registro. El primer backend que
/// retorna sin error gana. Si todos lanzan elementNotFound, relanza el último.
/// Cualquier otro error propaga inmediatamente sin escalar.
public actor ActionRouter {
    private let registry: CapabilityRegistry

    public init(registry: CapabilityRegistry) {
        self.registry = registry
    }

    public func execute(_ action: Action) async throws -> ActionResult {
        let kind = action.kind
        let candidates = await registry.capable(of: kind)

        guard !candidates.isEmpty else {
            throw ActionRouterError.noBackendForAction(kind)
        }

        var lastError: Error?
        for backend in candidates {
            do {
                return try await backend.execute(action)
            } catch let e as BridgeError {
                if case .elementNotFound = e {
                    lastError = e
                    continue
                }
                throw e
            }
        }
        throw lastError ?? ActionRouterError.noBackendForAction(kind)
    }
}
