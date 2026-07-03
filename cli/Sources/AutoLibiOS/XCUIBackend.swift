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

    // `.screenshot` NO está acá a propósito (#155): la captura del runner
    // (`XCUIApplication.screenshot()`) depende de la ventana del Simulator en
    // el Mac — si está tapada o parcialmente fuera de pantalla la imagen sale
    // recortada, y la resolución es la de la ventana, no la del device. El
    // router enruta screenshot a `MediaBackend` (framebuffer via
    // `simctl io <udid> screenshot`), que es independiente de la ventana.
    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        .scroll, .swipe,
        .tree, .search,
        .launchApp, .terminateApp,
        .typeText, .viewport,
        .exists, .isVisible, .hasText
    ]

    public static func make(xcuiBridge: XCUIBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(xcuiBridge)
        )
    }
}
