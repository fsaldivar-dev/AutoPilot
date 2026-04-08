import Foundation

/// Protocol that defines platform-agnostic device automation.
/// Implemented by SimulatorBridge (iOS) and future AdbBridge (Android).
public protocol DeviceBridge {

    // MARK: - Accessibility Tree

    func tree() throws -> [[String: Any]]
    func search(query: String) throws -> [[String: Any]]
    func elementAt(x: Double, y: Double) throws -> [String: Any]?

    // MARK: - Actions

    func tap(target: String) throws
    func longPress(target: String, duration: Double) throws
    func doubleTap(target: String) throws
    func clear(target: String) throws
    func typeText(_ text: String) throws
    func scroll(target: String, direction: String) throws
    func swipe(direction: String) throws
    func tapAtCoordinate(x: Double, y: Double) throws

    // MARK: - App Lifecycle

    func launchApp(bundleId: String, envVars: [String: String]) throws
    func terminateApp(bundleId: String) throws

    // MARK: - Device Management

    func listDevices() throws -> [[String: Any]]
    func bootDevice(_ nameOrUdid: String) throws
    func shutdownDevice(_ nameOrUdid: String) throws
    func installApp(path: String) throws
    func getBootedDeviceId() throws -> String

    // MARK: - Media & IO

    func screenshot(path: String) throws
    func addMedia(path: String) throws
    func openURL(_ url: String) throws
    func setPasteboard(text: String) throws
    func getPasteboard() throws -> String

    // MARK: - Biometric

    func biometricEnroll() throws      // Idempotente: enrolla solo si no está
    func biometricUnenroll() throws    // Idempotente: des-enrolla solo si está
    func biometricMatch() throws
    func biometricFail() throws
    func biometricIsEnrolled() throws -> Bool

    // MARK: - Logs

    func getLogs(bundleId: String?, lines: Int) throws -> String

    // MARK: - Permissions

    func setPermission(action: String, service: String, bundleId: String) throws

    // MARK: - Device Orientation

    func rotate(direction: String) throws

    // MARK: - Drag

    func drag(from: String, to: String, duration: Double) throws
    func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws

    // MARK: - Keyboard

    func pressKey(key: String) throws
    func hideKeyboard() throws
    func eraseText(count: Int) throws

    // MARK: - Text Extraction

    func copyTextFrom(target: String) throws -> String

    // MARK: - App Data

    func clearState(bundleId: String) throws
    func uninstallApp(bundleId: String) throws

    // MARK: - Secure Storage

    /// Reset the device's shared secure storage ("fresh credentials for
    /// next launch"). Cross-platform by design so the same `.auto` script
    /// runs on iOS and Android without branching.
    ///
    /// - **iOS Simulator**: wraps `xcrun simctl keychain <udid> reset`,
    ///   clearing credentials saved by Keychain Services across ALL apps
    ///   on the booted simulator. There is no per-bundle reset in simctl,
    ///   this is always device-wide.
    /// - **Android**: no-op with a printed note. The Android Keystore is
    ///   per-app and tied to the app's UID, so `uninstall <bundleId>`
    ///   already releases those keys on the next install. The post-
    ///   condition "fresh credential state for next launch" holds without
    ///   doing anything here, as long as the script has an `uninstall`
    ///   step before `install`.
    ///
    /// **Edge case (Android)**: apps that use `AccountManager` (Google
    /// Sign-In, "Continue with Google", Facebook Login) store their
    /// accounts in device-wide system services that survive
    /// `uninstall`. For those, add an explicit
    /// `clearState "com.google.android.gms"` step next to this one.
    /// Tracked in the follow-up issue for AccountManager clearing.
    func resetKeychain() throws

    // MARK: - Scroll Search

    func scrollTo(target: String, direction: String, maxAttempts: Int) throws

    // MARK: - Screen Recording

    func startRecording() throws
    func stopRecording(outputPath: String) throws

    // MARK: - Device Environment

    func setLocation(latitude: Double, longitude: Double) throws
    func setAppearance(mode: String) throws
    func lockDevice() throws
    func unlockDevice() throws

    // MARK: - File Transfer

    func pushFile(localPath: String, remotePath: String) throws
    func pullFile(remotePath: String, localPath: String) throws
}

// MARK: - Default implementations

/// Default implementations for methods whose behavior is
/// platform-asymmetric. Conforming types override only where they need
/// real work — everything else degrades to a documented no-op so the
/// same `.auto` script runs on iOS and Android without branching.
public extension DeviceBridge {
    /// Default: no-op with a printed note. The post-condition "fresh
    /// credential state for next launch" is already satisfied on Android
    /// by the per-app Keystore model (uninstall releases the UID and
    /// drops the keys), so this command has nothing to do there.
    ///
    /// The iOS `SimulatorBridge` overrides with a real `xcrun simctl
    /// keychain reset` because iOS's shared keychain DOES persist
    /// credentials across uninstall/install of a bundle.
    ///
    /// This makes `keychain reset` a safe cross-platform step: iOS wipes
    /// the device-wide keychain, Android does nothing (which is correct
    /// because it was already handled by `uninstall`).
    func resetKeychain() throws {
        print("Keychain reset: no-op on this platform (Android Keystore is per-app, already cleared by uninstall)")
    }
}
