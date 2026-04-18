import Foundation

/// Backend Android via socket TCP al agente nativo (UiAutomation + JVMTI).
/// Default para Android — más rápido y con más capabilities que adb.
///
/// **Fase 3b (actual):** envuelve `AgentBridge`. La extracción del acoplamiento
/// interno con `AdbLegacyBridge` queda para un PR futuro focalizado en eso.
public enum AgentBackend {

    public static let capabilities: Set<ActionKind> = [
        .tap, .doubleTap, .longPress, .clear,
        .scroll, .swipe, .tapAtCoordinate,
        .drag, .dragCoordinates,
        .tree, .search, .elementAt,
        .typeText, .eraseText, .pressKey, .hideKeyboard, .copyTextFrom,
        .scrollTo, .viewport,
        .launchApp, .terminateApp, .clearState, .uninstallApp,
        .listDevices, .bootDevice, .shutdownDevice, .installApp, .getBootedDeviceId,
        .screenshot, .addMedia, .openURL, .setPasteboard, .getPasteboard,
        .getLogs, .setPermission,
        .rotate, .lockDevice, .unlockDevice, .resetKeychain,
        .startRecording, .stopRecording,
        .setLocation, .setAppearance,
        .pushFile, .pullFile,
        .biometricEnroll, .biometricUnenroll, .biometricMatch, .biometricFail, .biometricIsEnrolled
    ]

    public static func make(agentBridge: AgentBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(agentBridge)
        )
    }
}
