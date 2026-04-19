import Foundation
import AutoCore

/// Backend iOS de captura de media: screenshot y screen recording.
/// Aislado porque recording mantiene estado (proceso en vuelo) — mezclarlo con
/// input y device mgmt hacía difícil razonar sobre el lifecycle.
///
/// **Fase 3a (actual):** envuelve `SimulatorBridge`. La extracción del state
/// machine de recording queda para un PR futuro.
public enum MediaBackend {

    public static let capabilities: Set<ActionKind> = [
        .screenshot,
        .startRecording,
        .stopRecording
    ]

    public static func make(simulatorBridge: SimulatorBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(simulatorBridge)
        )
    }
}
