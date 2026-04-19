import Foundation

/// Bootstrap de plataforma: detecta el dispositivo disponible, construye los
/// backends correspondientes, los registra en el `ActionRouter`, y expone el
/// resultado listo para ejecutar acciones.
///
/// Cada plataforma implementa su propio resolver (iOSDeviceResolver,
/// AndroidDeviceResolver). Los CLIs no tocan `CapabilityRegistry` directamente —
/// solo piden `router` al resolver y lo usan.
///
/// Ver ARD-001 (docs/rfc/ARD-001-backend-pattern.md) para el contexto arquitectural.
public protocol DeviceResolver {
    /// El router listo para despachar acciones, con los backends de la plataforma
    /// registrados en orden de prioridad.
    var router: ActionRouter { get }
}

/// Helper para registrar múltiples backends en un registry de forma síncrona
/// (bloqueando) durante el bootstrap. Útil para inicialización global.
public func registerBackendsSynchronously(_ backends: [any Backend], in registry: CapabilityRegistry) {
    let group = DispatchGroup()
    group.enter()
    Task {
        for backend in backends {
            await registry.register(backend)
        }
        group.leave()
    }
    group.wait()
}
