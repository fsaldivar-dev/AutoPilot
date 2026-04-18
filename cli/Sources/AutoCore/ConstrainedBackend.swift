import Foundation

/// Backend que restringe las capabilities de un delegate. Permite construir
/// backends focalizados (AXBackend, SimCtlBackend, etc.) sobre la misma
/// implementación subyacente, declarando solo lo que cada uno sabe hacer.
///
/// El `ActionRouter` enruta por capability — si el action.kind no está en
/// `capabilities`, este backend ni siquiera es consultado.
public final class ConstrainedBackend: Backend, @unchecked Sendable {
    public let capabilities: Set<ActionKind>
    private let delegate: any Backend

    public init(capabilities: Set<ActionKind>, delegate: any Backend) {
        self.capabilities = capabilities
        self.delegate = delegate
    }

    public func execute(_ action: Action) async throws -> ActionResult {
        // Sanity check: el router no debería mandar acciones fuera del set
        // de capabilities, pero si pasa lo atrapamos acá explícitamente.
        guard capabilities.contains(action.kind) else {
            throw ActionRouterError.noBackendForAction(action.kind)
        }
        return try await delegate.execute(action)
    }
}
