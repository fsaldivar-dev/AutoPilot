import Foundation
import CoreGraphics
import AutoCore

// MARK: - ObserverBridge
//
// Puts the ARD-002 in-process observer in the fast path for UI operations
// (tree / tap / typeText / etc.) and delegates everything else (lifecycle,
// media, biometric, device mgmt) to the existing HybridBridge.
//
// Used as the legacyBridge in iOSDeviceResolver when the observer is reachable.
// Mirrors the HybridBridge pattern — try observer first, escalate on error.

public final class ObserverBridge: DeviceBridge {

    private let observer: iOSAgentBridge
    private let fallback: any DeviceBridge

    public init(observer: iOSAgentBridge, fallback: any DeviceBridge) {
        self.observer = observer
        self.fallback = fallback
    }

    // MARK: - UI ops — observer first, fallback on elementNotFound

    public func tree() throws -> [[String: Any]] {
        do { return try observer.tree() } catch { return try fallback.tree() }
    }

    public func search(query: String) throws -> [[String: Any]] {
        do { return try observer.search(query: query) } catch { return try fallback.search(query: query) }
    }

    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        do { return try observer.elementAt(x: x, y: y) } catch { return try fallback.elementAt(x: x, y: y) }
    }

    public func tap(target: String) throws {
        do { try observer.tap(target: target) }
        catch let e as BridgeError {
            if case .elementNotFound = e { try fallback.tap(target: target) } else { throw e }
        }
    }

    public func doubleTap(target: String) throws {
        do { try observer.doubleTap(target: target) }
        catch let e as BridgeError {
            if case .elementNotFound = e { try fallback.doubleTap(target: target) } else { throw e }
        }
    }

    public func longPress(target: String, duration: Double) throws {
        do { try observer.longPress(target: target, duration: duration) }
        catch let e as BridgeError {
            if case .elementNotFound = e { try fallback.longPress(target: target, duration: duration) } else { throw e }
        }
    }

    public func clear(target: String) throws {
        do { try observer.clear(target: target) }
        catch let e as BridgeError {
            if case .elementNotFound = e { try fallback.clear(target: target) } else { throw e }
        }
    }

    public func typeText(_ text: String) throws {
        do { try observer.typeText(text) } catch { try fallback.typeText(text) }
    }

    public func scroll(target: String, direction: String) throws {
        do { try observer.scroll(target: target, direction: direction) }
        catch let e as BridgeError {
            if case .elementNotFound = e { try fallback.scroll(target: target, direction: direction) } else { throw e }
        }
    }

    public func swipe(direction: String) throws {
        do { try observer.swipe(direction: direction) } catch { try fallback.swipe(direction: direction) }
    }

    public func tapAtCoordinate(x: Double, y: Double) throws {
        do { try observer.tapAtCoordinate(x: x, y: y) } catch { try fallback.tapAtCoordinate(x: x, y: y) }
    }

    public func drag(from: String, to: String, duration: Double) throws {
        try fallback.drag(from: from, to: to, duration: duration)
    }

    public func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
        try fallback.dragCoordinates(x1: x1, y1: y1, x2: x2, y2: y2, duration: duration)
    }

    public func pressKey(key: String) throws {
        do { try observer.pressKey(key: key) } catch { try fallback.pressKey(key: key) }
    }

    public func hideKeyboard() throws {
        do { try observer.hideKeyboard() } catch { try fallback.hideKeyboard() }
    }

    public func eraseText(count: Int) throws {
        try fallback.eraseText(count: count)
    }

    public func copyTextFrom(target: String) throws -> String {
        try fallback.copyTextFrom(target: target)
    }

    public func viewport() throws -> CGRect {
        do { return try observer.viewport() } catch { return try fallback.viewport() }
    }

    // MARK: - Lifecycle, media, device — always fallback

    public func launchApp(bundleId: String, envVars: [String: String]) throws {
        try fallback.launchApp(bundleId: bundleId, envVars: envVars)
    }

    public func terminateApp(bundleId: String) throws {
        try fallback.terminateApp(bundleId: bundleId)
    }

    public func listDevices() throws -> [[String: Any]] {
        try fallback.listDevices()
    }

    public func bootDevice(_ nameOrUdid: String) throws {
        try fallback.bootDevice(nameOrUdid)
    }

    public func shutdownDevice(_ nameOrUdid: String) throws {
        try fallback.shutdownDevice(nameOrUdid)
    }

    public func installApp(path: String) throws {
        try fallback.installApp(path: path)
    }

    public func getBootedDeviceId() throws -> String {
        try fallback.getBootedDeviceId()
    }

    public func screenshot(path: String) throws {
        try fallback.screenshot(path: path)
    }

    public func addMedia(path: String) throws {
        try fallback.addMedia(path: path)
    }

    public func openURL(_ url: String) throws {
        try fallback.openURL(url)
    }

    public func setPasteboard(text: String) throws {
        try fallback.setPasteboard(text: text)
    }

    public func getPasteboard() throws -> String {
        try fallback.getPasteboard()
    }

    public func biometricEnroll() throws {
        try fallback.biometricEnroll()
    }

    public func biometricUnenroll() throws {
        try fallback.biometricUnenroll()
    }

    public func biometricMatch() throws {
        try fallback.biometricMatch()
    }

    public func biometricFail() throws {
        try fallback.biometricFail()
    }

    public func biometricIsEnrolled() throws -> Bool {
        try fallback.biometricIsEnrolled()
    }

    public func getLogs(bundleId: String?, lines: Int) throws -> String {
        try fallback.getLogs(bundleId: bundleId, lines: lines)
    }

    public func setPermission(action: String, service: String, bundleId: String) throws {
        try fallback.setPermission(action: action, service: service, bundleId: bundleId)
    }

    public func rotate(direction: String) throws {
        try fallback.rotate(direction: direction)
    }

    public func clearState(bundleId: String) throws {
        try fallback.clearState(bundleId: bundleId)
    }

    public func uninstallApp(bundleId: String) throws {
        try fallback.uninstallApp(bundleId: bundleId)
    }

    public func startRecording() throws {
        try fallback.startRecording()
    }

    public func stopRecording(outputPath: String) throws {
        try fallback.stopRecording(outputPath: outputPath)
    }

    public func setLocation(latitude: Double, longitude: Double) throws {
        try fallback.setLocation(latitude: latitude, longitude: longitude)
    }

    public func setAppearance(mode: String) throws {
        try fallback.setAppearance(mode: mode)
    }

    public func lockDevice() throws {
        try fallback.lockDevice()
    }

    public func unlockDevice() throws {
        try fallback.unlockDevice()
    }

    public func pushFile(localPath: String, remotePath: String) throws {
        try fallback.pushFile(localPath: localPath, remotePath: remotePath)
    }

    public func pullFile(remotePath: String, localPath: String) throws {
        try fallback.pullFile(remotePath: remotePath, localPath: localPath)
    }
}
