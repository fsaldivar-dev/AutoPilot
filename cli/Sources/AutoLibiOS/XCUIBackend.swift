import Foundation
import AutoCore

/// Backend iOS de XCUITest vía daemon + XCUIApplication. Deep path — ve NavBar
/// SwiftUI, modales, y elementos que AX macOS aplana.
///
/// Este backend **solo declara las capabilities que realmente implementa**.
/// Los métodos que `XCUIBridge` lanzaba como `notImplemented()` simplemente
/// no están en `capabilities` — el router nunca los enruta acá.
///
/// En combinación con `AXBackend`:
/// - AX registrado primero → fast path
/// - XCUI registrado segundo → escalation automático cuando AX lanza elementNotFound
///
/// Esto reemplaza el `HybridBridge` (que se elimina en Fase 4).
public enum XCUIBackend {

    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        .scroll, .swipe,
        .tree, .search,
        .launchApp, .terminateApp,
        .typeText, .screenshot, .viewport,
        .exists, .isVisible, .hasText
    ]

    public static func make(xcuiBridge: XCUIBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(xcuiBridge)
        )
    }
}
