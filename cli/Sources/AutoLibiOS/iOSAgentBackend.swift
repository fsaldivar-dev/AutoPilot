import AutoCore

/// Backend factory for the ARD-002 in-process iOS observer.
/// Registered by iOSDeviceResolver when the observer socket is reachable (port 7002).
/// Takes priority over AXBackend — sub-10ms tree queries from inside the app process.
public enum iOSAgentBackend {

    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        .scroll, .swipe, .tapAtCoordinate,
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
