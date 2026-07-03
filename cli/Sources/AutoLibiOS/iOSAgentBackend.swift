import AutoCore

/// Backend factory for the ARD-002 in-process iOS observer.
/// Registered by iOSDeviceResolver when the observer socket is reachable (port 7002).
/// Takes priority over AXBackend — sub-10ms tree queries from inside the app process.
public enum iOSAgentBackend {

    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        // `.scrollTo` (#153): ejecuta el scrollTo compartido de DeviceBridge
        // sobre tree/swipe/viewport del observer. Sin esta capability el
        // router caía siempre al legacyBridge XCUI, cuyo snapshot NO expone
        // elementos SwiftUI offscreen (no puede ni encontrar el target) y
        // paga ~13s por tree. El observer los ve en ~3ms. AgentBackend
        // (Android) ya la declaraba — esto empareja iOS.
        .scroll, .swipe, .scrollTo, .tapAtCoordinate,
        .tree, .search, .elementAt,
        .typeText, .pressKey, .hideKeyboard,
        .viewport,
    ]

    public static func make(bridge: iOSAgentBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(bridge)
        )
    }
}
