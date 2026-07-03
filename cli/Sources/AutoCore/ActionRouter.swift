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
///
/// Degradación por conexión (#154): si un backend lanza
/// `BridgeError.connectionFailed` (socket muerto, observer/agente caído),
/// el router NO aborta el run — avisa una vez por backend y degrada al
/// siguiente que declare la capability. Si la degradación funciona (otro
/// backend responde), el backend muerto queda en cuarentena por el resto
/// del proceso: no se vuelve a intentar en ninguna acción. Si NADIE responde,
/// no hay cuarentena — la próxima acción reintenta desde el principio
/// (el fallo pudo ser transitorio).
///
/// Cualquier otro error propaga inmediatamente sin escalar.
public actor ActionRouter {
    private let registry: CapabilityRegistry

    /// Backends muertos por conexión cuya degradación ya funcionó — se
    /// saltan por el resto del proceso (#154).
    private var quarantined: Set<ObjectIdentifier> = []

    /// Backends por los que ya avisamos un fallo de conexión — el warning
    /// se imprime una sola vez por backend, no por acción.
    private var warnedConnection: Set<ObjectIdentifier> = []

    public init(registry: CapabilityRegistry) {
        self.registry = registry
    }

    public func execute(_ action: Action) async throws -> ActionResult {
        let kind = action.kind
        let candidates = await registry.capable(of: kind)
            .filter { !quarantined.contains(ObjectIdentifier($0)) }

        guard !candidates.isEmpty else {
            throw ActionRouterError.noBackendForAction(kind)
        }

        var lastError: Error?
        var deadThisCall: [any Backend] = []
        for backend in candidates {
            do {
                let result = try await backend.execute(action)
                // Degradación exitosa: des-registrar los backends que fallaron
                // por conexión en ESTA llamada — están muertos y ya hay un
                // reemplazo funcionando.
                for dead in deadThisCall where quarantined.insert(ObjectIdentifier(dead)).inserted {
                    fputs("[router] \(dead.name) queda fuera por el resto del proceso — \(backend.name) responde en su lugar\n", stderr)
                }
                return result
            } catch let e as BridgeError {
                switch e {
                case .elementNotFound:
                    lastError = e
                    continue
                case .connectionFailed:
                    if warnedConnection.insert(ObjectIdentifier(backend)).inserted {
                        fputs("[router] warning: \(backend.name) sin conexión (\(e)) — degradando al siguiente backend\n", stderr)
                    }
                    deadThisCall.append(backend)
                    lastError = e
                    continue
                default:
                    throw e
                }
            }
        }
        throw lastError ?? ActionRouterError.noBackendForAction(kind)
    }
}
