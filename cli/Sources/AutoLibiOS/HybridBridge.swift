import Foundation
import AutoCore

// MARK: - HybridBridge (DEPRECATED — será eliminado en Fase 5)
//
// Reemplazado por `ActionRouter` + `AXBackend` + `XCUIBackend` registrados
// en orden (ARD-001). El router hace el escalation automático al siguiente
// backend capaz cuando el primero lanza `BridgeError.elementNotFound` —
// eso elimina la necesidad de este wrapper.
//
// Aún vivo durante la transición porque `AUTO_BRIDGE=hybrid` (el default)
// lo consume. Sale cuando todos los comandos del CLI pasen por el router
// y ya nadie use `bridge.tap(...)` directo.

public final class HybridBridge: DeviceBridge {

    private let fast: DeviceBridge
    private let deep: DeviceBridge

    // Stats
    private(set) var fastCount = 0
    private(set) var deepCount = 0
    private(set) var escalationCount = 0

    public init(fast: DeviceBridge, deep: DeviceBridge) {
        self.fast = fast
        self.deep = deep
    }

    // MARK: - Escalation helper

    /// Escala al backend deep cuando el fast no encontró el elemento O cuando
    /// no soporta la operación. Esto último permite usar el observer (que lanza
    /// "not supported/implemented" para device-mgmt y algunos gestos) como fast
    /// path con XCUI de fallback, sin romper esos comandos (#165).
    private func shouldEscalate(_ error: BridgeError) -> Bool {
        if case .elementNotFound = error { return true }
        if case .unknown(let msg) = error {
            let m = msg.lowercased()
            return m.contains("not supported") || m.contains("not implemented")
        }
        return false
    }

    /// Try fast, if not-found / not-supported → retry with deep.
    private func escalate(_ action: String, fast fastFn: () throws -> Void, deep deepFn: () throws -> Void) throws {
        do {
            try fastFn()
            fastCount += 1
        } catch let error as BridgeError {
            if shouldEscalate(error) {
                escalationCount += 1
                deepCount += 1
                try deepFn()
            } else {
                throw error
            }
        }
    }

    /// Try fast returning a value, if not-found / not-supported → retry with deep.
    private func escalateValue<T>(_ action: String, fast fastFn: () throws -> T, deep deepFn: () throws -> T) throws -> T {
        do {
            let result = try fastFn()
            fastCount += 1
            return result
        } catch let error as BridgeError {
            if shouldEscalate(error) {
                escalationCount += 1
                deepCount += 1
                return try deepFn()
            } else {
                throw error
            }
        }
    }

    // MARK: - Stats

    public func stats() -> String {
        "fast=\(fastCount) deep=\(deepCount) escalations=\(escalationCount)"
    }

    // MARK: - Accessibility Tree

    public func tree() throws -> [[String: Any]] {
        // Tree always from fast (SimulatorBridge) — it's the primary view.
        // Deep tree available via AUTO_BRIDGE=xcui if needed.
        fastCount += 1
        return try fast.tree()
    }

    public func search(query: String) throws -> [[String: Any]] {
        // Search with escalation: if fast finds nothing, try deep
        let fastResults = try fast.search(query: query)
        if !fastResults.isEmpty {
            fastCount += 1
            return fastResults
        }
        // Fast returned empty — try deep
        do {
            let deepResults = try deep.search(query: query)
            if !deepResults.isEmpty {
                escalationCount += 1
                deepCount += 1
                return deepResults
            }
        } catch {
            // Deep also failed — return fast's empty result
        }
        fastCount += 1
        return fastResults
    }

    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        fastCount += 1
        return try fast.elementAt(x: x, y: y)
    }

    // MARK: - Actions (escalatable)

    public func tap(target: String) throws {
        try escalate("tap",
                     fast: { try self.fast.tap(target: target) },
                     deep: { try self.deep.tap(target: target) })
    }

    public func longPress(target: String, duration: Double) throws {
        try escalate("longPress",
                     fast: { try self.fast.longPress(target: target, duration: duration) },
                     deep: { try self.deep.longPress(target: target, duration: duration) })
    }

    public func doubleTap(target: String) throws {
        try escalate("doubleTap",
                     fast: { try self.fast.doubleTap(target: target) },
                     deep: { try self.deep.doubleTap(target: target) })
    }

    public func clear(target: String) throws {
        try escalate("clear",
                     fast: { try self.fast.clear(target: target) },
                     deep: { try self.deep.clear(target: target) })
    }

    public func typeText(_ text: String) throws {
        // typeText doesn't target an element — no escalation needed
        fastCount += 1
        try fast.typeText(text)
    }

    public func scroll(target: String, direction: String) throws {
        try escalate("scroll",
                     fast: { try self.fast.scroll(target: target, direction: direction) },
                     deep: { try self.deep.scroll(target: target, direction: direction) })
    }

    public func swipe(direction: String) throws {
        fastCount += 1
        try fast.swipe(direction: direction)
    }

    public func tapAtCoordinate(x: Double, y: Double) throws {
        fastCount += 1
        try fast.tapAtCoordinate(x: x, y: y)
    }

    // MARK: - App Lifecycle (fast only — simctl is reliable)

    public func launchApp(bundleId: String, envVars: [String: String]) throws {
        fastCount += 1
        try fast.launchApp(bundleId: bundleId, envVars: envVars)
    }

    public func terminateApp(bundleId: String) throws {
        fastCount += 1
        try fast.terminateApp(bundleId: bundleId)
    }

    // MARK: - Device Management (fast only)

    public func listDevices() throws -> [[String: Any]]     { fastCount += 1; return try fast.listDevices() }
    public func bootDevice(_ n: String) throws              { fastCount += 1; try fast.bootDevice(n) }
    public func shutdownDevice(_ n: String) throws          { fastCount += 1; try fast.shutdownDevice(n) }
    public func installApp(path: String) throws             { fastCount += 1; try fast.installApp(path: path) }
    public func getBootedDeviceId() throws -> String        { fastCount += 1; return try fast.getBootedDeviceId() }

    // MARK: - Media & IO (fast only)

    public func screenshot(path: String) throws             { fastCount += 1; try fast.screenshot(path: path) }
    public func addMedia(path: String) throws               { fastCount += 1; try fast.addMedia(path: path) }
    public func openURL(_ url: String) throws               { fastCount += 1; try fast.openURL(url) }
    public func setPasteboard(text: String) throws          { fastCount += 1; try fast.setPasteboard(text: text) }
    public func getPasteboard() throws -> String            { fastCount += 1; return try fast.getPasteboard() }

    // MARK: - Biometric (fast only)

    public func biometricEnroll() throws                    { fastCount += 1; try fast.biometricEnroll() }
    public func biometricUnenroll() throws                  { fastCount += 1; try fast.biometricUnenroll() }
    public func biometricMatch() throws                     { fastCount += 1; try fast.biometricMatch() }
    public func biometricFail() throws                      { fastCount += 1; try fast.biometricFail() }
    public func biometricIsEnrolled() throws -> Bool        { fastCount += 1; return try fast.biometricIsEnrolled() }

    // MARK: - Logs / Permissions (fast only)

    public func getLogs(bundleId: String?, lines: Int) throws -> String {
        fastCount += 1; return try fast.getLogs(bundleId: bundleId, lines: lines)
    }
    public func setPermission(action: String, service: String, bundleId: String) throws {
        fastCount += 1; try fast.setPermission(action: action, service: service, bundleId: bundleId)
    }

    // MARK: - Orientation / Drag (fast only)

    public func rotate(direction: String) throws                    { fastCount += 1; try fast.rotate(direction: direction) }
    public func drag(from: String, to: String, duration: Double) throws { fastCount += 1; try fast.drag(from: from, to: to, duration: duration) }
    public func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
        fastCount += 1; try fast.dragCoordinates(x1: x1, y1: y1, x2: x2, y2: y2, duration: duration)
    }

    // MARK: - Keyboard (fast only)

    public func pressKey(key: String) throws    { fastCount += 1; try fast.pressKey(key: key) }
    public func hideKeyboard() throws           { fastCount += 1; try fast.hideKeyboard() }
    public func eraseText(count: Int) throws    { fastCount += 1; try fast.eraseText(count: count) }

    // MARK: - Text / App Data (escalatable for copyTextFrom)

    public func copyTextFrom(target: String) throws -> String {
        return try escalateValue("copyTextFrom",
                                fast: { try self.fast.copyTextFrom(target: target) },
                                deep: { try self.deep.copyTextFrom(target: target) })
    }

    public func clearState(bundleId: String) throws { fastCount += 1; try fast.clearState(bundleId: bundleId) }
    public func uninstallApp(bundleId: String) throws { fastCount += 1; try fast.uninstallApp(bundleId: bundleId) }

    // MARK: - Scroll Search (escalatable)

    public func scrollTo(target: String, direction: String, maxAttempts: Int) throws {
        try escalate("scrollTo",
                     fast: { try self.fast.scrollTo(target: target, direction: direction, maxAttempts: maxAttempts) },
                     deep: { try self.deep.scrollTo(target: target, direction: direction, maxAttempts: maxAttempts) })
    }

    // MARK: - Viewport

    public func viewport() throws -> CGRect {
        // Viewport = screen bounds. Siempre delegamos al fast porque el
        // Simulator window frame es lo más fiable en iOS y es idéntico al
        // app.frame que devuelve XCUI en este contexto.
        fastCount += 1
        return try fast.viewport()
    }

    // MARK: - Recording / Environment (fast only)

    public func startRecording() throws                     { fastCount += 1; try fast.startRecording() }
    public func stopRecording(outputPath: String) throws    { fastCount += 1; try fast.stopRecording(outputPath: outputPath) }
    public func setLocation(latitude: Double, longitude: Double) throws { fastCount += 1; try fast.setLocation(latitude: latitude, longitude: longitude) }
    public func setAppearance(mode: String) throws          { fastCount += 1; try fast.setAppearance(mode: mode) }
    public func lockDevice() throws                         { fastCount += 1; try fast.lockDevice() }
    public func unlockDevice() throws                       { fastCount += 1; try fast.unlockDevice() }
    public func pushFile(localPath: String, remotePath: String) throws { fastCount += 1; try fast.pushFile(localPath: localPath, remotePath: remotePath) }
    public func pullFile(remotePath: String, localPath: String) throws { fastCount += 1; try fast.pullFile(remotePath: remotePath, localPath: localPath) }
}
