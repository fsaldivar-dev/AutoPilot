import Foundation
import AutoCore

/// Backend iOS de device management vía `xcrun simctl` y AppleScript.
/// Install, launch, biometría, permisos, keychain, rotate, location, etc.
///
/// Capabilities: everything que llama simctl (no AX, no media recording).
///
/// **Fase 3a (actual):** envuelve `SimulatorBridge`. La extracción del código
/// simctl queda para un PR futuro.
public enum SimCtlBackend {

    public static let capabilities: Set<ActionKind> = [
        .launchApp, .terminateApp, .clearState, .uninstallApp,
        .listDevices, .bootDevice, .shutdownDevice, .installApp, .getBootedDeviceId,
        .openURL, .setPasteboard, .getPasteboard, .addMedia,
        .biometricEnroll, .biometricUnenroll, .biometricMatch, .biometricFail, .biometricIsEnrolled,
        .getLogs, .setPermission,
        .rotate, .lockDevice, .unlockDevice, .resetKeychain,
        .setLocation, .setAppearance,
        .pushFile, .pullFile
    ]

    public static func make(simulatorBridge: SimulatorBridge) -> any Backend {
        ConstrainedBackend(
            capabilities: capabilities,
            delegate: LegacyBridgeAdapter(simulatorBridge)
        )
    }
}
