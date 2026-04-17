import Foundation
import CoreGraphics

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

    // MARK: - Viewport

    /// Screen bounds del dispositivo/simulador en coordenadas de pantalla.
    /// Usado por `scrollTo` y el recorder para decidir si un elemento está
    /// dentro del viewport visible.
    ///
    /// - iOS Simulator (fast): frame de la ventana del Simulator (AX macOS)
    /// - iOS XCUI: `XCUIApplication.frame` del runner
    /// - Android agent: displayMetrics del dispositivo
    /// - Android adb: `adb shell wm size`
    func viewport() throws -> CGRect

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

    /// Scroll until the element is VISIBLE in the viewport (≥50% covered).
    /// The AX/UI trees include offscreen elements, so just finding a match in
    /// the tree isn't enough — we validate viewport intersection before
    /// reporting success. `HybridBridge` overrides this to escalate to the
    /// deep bridge on `elementNotFound`.
    ///
    /// Multi-match semantics: if the target label matches multiple elements,
    /// any visible match satisfies the search (the user cares that *some*
    /// "X" is tappable, not which one). The explicit `Label[N]` index path
    /// still pins to the N-th occurrence.
    ///
    /// Frameless match fallback: if a match exists in the tree but has no
    /// usable frame (e.g. containers, separators), we treat it as "found" —
    /// scrolling blindly toward it would timeout with no recovery.
    func scrollTo(target: String, direction: String, maxAttempts: Int) throws {
        let screen = try viewport()
        let hasExplicitIndex = TargetResolverShared.parse(target).index != nil
        for _ in 0..<maxAttempts {
            let currentTree = try tree()
            let matches = explicitMatches(in: currentTree, target: target, explicitIndex: hasExplicitIndex)

            var sawMatchWithoutFrame = false
            for match in matches {
                guard let frame = ViewportUtil.rect(from: match["frame"] as? [String: Any]) else {
                    sawMatchWithoutFrame = true
                    continue
                }
                let vp = ViewportUtil.resolveViewport(for: match, in: currentTree, screenBounds: screen)
                if ViewportUtil.isVisible(frame: frame, inViewport: vp) {
                    return
                }
            }
            if sawMatchWithoutFrame && matches.allSatisfy({ ViewportUtil.rect(from: $0["frame"] as? [String: Any]) == nil }) {
                return
            }

            try swipe(direction: direction)
            usleep(500_000)
        }
        throw BridgeError.elementNotFound("Could not scroll to visible: '\(target)' after \(maxAttempts) attempts")
    }

    private func explicitMatches(in tree: [[String: Any]], target: String, explicitIndex: Bool) -> [[String: Any]] {
        if explicitIndex {
            if let match = ViewportUtil.findFirst(in: tree, matching: target) {
                return [match]
            }
            return []
        }
        let parsed = TargetResolverShared.parse(target)
        return TargetResolverShared.findAll(in: tree, matching: parsed.label).map { $0.element }
    }
}
