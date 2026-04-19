import Foundation

/// Backend Android fallback via `adb shell` + uiautomator dump.
/// Más lento que AgentBackend pero no requiere el agente instalado.
/// Activado con `auto-android --legacy`.
///
/// **Fase 3b (actual):** envuelve `AdbLegacyBridge`. La extracción de los
/// regex de parseo queda para un PR futuro.
public enum AdbBackend {

    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        .scroll, .swipe, .tapAtCoordinate,
        .drag, .dragCoordinates,
        .tree, .search, .elementAt,
        .typeText, .eraseText, .pressKey, .hideKeyboard, .copyTextFrom,
        .scrollTo, .viewport,
        .launchApp, .terminateApp, .clearState, .uninstallApp,
        .listDevices, .bootDevice, .shutdownDevice, .installApp, .getBootedDeviceId,
        .screenshot, .setPasteboard,
        .getLogs, .setPermission,
        .rotate, .lockDevice, .unlockDevice,
        .startRecording, .stopRecording,
        .setLocation, .setAppearance,
        .pushFile, .pullFile
    ]

    public static func make(adbBridge: AdbLegacyBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(adbBridge)
        )
    }
}
