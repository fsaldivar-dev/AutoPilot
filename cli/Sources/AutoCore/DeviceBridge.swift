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

    // MARK: - Device Orientation

    func rotate(direction: String) throws

    // MARK: - Drag

    func drag(from: String, to: String, duration: Double) throws
    func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws
}
