import Foundation
import AutoCore

/// Backend iOS de AX + CGEvent input. Fast path — ve la AX tree macOS pero
/// ciego a NavBar SwiftUI (eso lo maneja XCUIBackend, el router escala).
///
/// Capabilities: tap, gestures, tree, search, input, scroll.
/// NO declara: install, biometric, screenshot, recording — esas son otros backends.
///
/// **Fase 3a (actual):** envuelve `SimulatorBridge` existente. El código de
/// AXUIElement sigue viviendo en `SimulatorBridge.swift` temporalmente.
/// **Fase 3a post-refactor:** extraer la lógica AX a este archivo (~400 LOC).
public enum AXBackend {

    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        .scroll, .swipe, .tapAtCoordinate,
        .drag, .dragCoordinates,
        .tree, .search, .elementAt,
        .typeText, .eraseText, .pressKey, .hideKeyboard, .copyTextFrom,
        .scrollTo, .viewport,
        .exists, .isVisible, .hasText, .getPlatform, .getOrientation
    ]

    public static func make(simulatorBridge: SimulatorBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(simulatorBridge)
        )
    }
}
