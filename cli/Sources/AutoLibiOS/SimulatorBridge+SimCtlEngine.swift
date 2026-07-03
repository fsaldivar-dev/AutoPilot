import Foundation
import ApplicationServices
import AppKit
import AutoCore

// MARK: - SimCtlEngine
//
// Device management + app lifecycle + biometry + permissions + keychain iOS.
// Extraído de `SimulatorBridge.swift` — wrappers sobre `xcrun simctl` y
// `osascript` al Simulator.app. La API pública del bridge no cambia.
//
// Responsabilidades:
//   - `getBootedDeviceId` / `listDevices` / `bootDevice` / `shutdownDevice`
//   - `launchApp` / `terminateApp` / `installApp` / `uninstallApp` / `clearState`
//   - `openURL` / `setPasteboard` / `getPasteboard`
//   - Biometric: `biometricEnroll/Unenroll/Match/Fail/IsEnrolled` + faceID aliases
//   - `getLogs` / `setPermission` / `resetKeychain`
//   - `pressKey` / `hideKeyboard` / `eraseText`
//   - `rotate` / `lockDevice` / `unlockDevice`
//   - `setLocation` / `setAppearance` / `viewport`
//   - `pushFile` / `pullFile`
//   - Helpers privados: `activateSimulatorApp`, `clickSimulatorMenu`,
//     `resolveDeviceUdid`, `toggleBiometricEnrollment`

extension SimulatorBridge {

    // MARK: - Boot / Shutdown / List / Device ID

    public func getBootedDeviceId() throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "booted", "-j"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else {
            throw BridgeError.noBootedDevice
        }

        for (_, deviceList) in devices {
            if let list = deviceList as? [[String: Any]] {
                for device in list {
                    if device["state"] as? String == "Booted",
                       let udid = device["udid"] as? String {
                        return udid
                    }
                }
            }
        }
        throw BridgeError.noBootedDevice
    }

    /// List available simulators.
    public func listDevices() throws -> [[String: Any]] {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "-j"]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let devices = json["devices"] as? [String: Any] else {
            return []
        }

        var result: [[String: Any]] = []
        for (runtime, deviceList) in devices {
            guard let list = deviceList as? [[String: Any]] else { continue }
            // Extract OS name from runtime key (e.g. "com.apple.CoreSimulator.SimRuntime.iOS-18-0" -> "iOS 18.0")
            let os = runtime.components(separatedBy: ".").last?.replacingOccurrences(of: "-", with: ".") ?? runtime
            for device in list {
                let name = device["name"] as? String ?? "Unknown"
                let udid = device["udid"] as? String ?? ""
                let state = device["state"] as? String ?? "Unknown"
                result.append(["name": name, "udid": udid, "state": state, "os": os])
            }
        }
        return result
    }

    /// Boot a simulator by name or UDID.
    public func bootDevice(_ nameOrUdid: String) throws {
        let udid = try resolveDeviceUdid(nameOrUdid)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "boot", udid]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw BridgeError.simctlFailed(errMsg)
        }

        // `simctl boot` solo arranca el device en CoreSimulator daemon (headless).
        // Para que el usuario vea la ventana, abrimos Simulator.app — si ya está
        // corriendo, `open -a` le manda focus sin relanzarlo.
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-a", "Simulator"]
        try? open.run()
        open.waitUntilExit()
    }

    /// Shutdown a simulator by name or UDID.
    public func shutdownDevice(_ nameOrUdid: String) throws {
        let udid = try resolveDeviceUdid(nameOrUdid)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "shutdown", udid]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw BridgeError.simctlFailed(errMsg)
        }
    }

    /// Resolve a device name to its UDID. If already a UDID, return as-is.
    private func resolveDeviceUdid(_ nameOrUdid: String) throws -> String {
        // If it looks like a UDID, use directly
        if nameOrUdid.count > 30 && nameOrUdid.contains("-") {
            return nameOrUdid
        }
        let devices = try listDevices()
        let lowered = nameOrUdid.lowercased()
        guard let match = devices.first(where: { ($0["name"] as? String ?? "").lowercased() == lowered }) else {
            throw BridgeError.deviceNotFound(nameOrUdid)
        }
        return match["udid"] as! String
    }

    // MARK: - App lifecycle

    /// Launch an app on the simulator.
    public func launchApp(bundleId: String, envVars: [String: String] = [:]) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "launch", deviceId, bundleId]

        // Inject environment variables via SIMCTL_CHILD_ prefix
        if !envVars.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (key, value) in envVars {
                env["SIMCTL_CHILD_\(key)"] = value
            }
            process.environment = env
        }

        try process.run()
        process.waitUntilExit()
    }

    /// Terminate an app on the simulator.
    public func terminateApp(bundleId: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "terminate", deviceId, bundleId]
        try process.run()
        process.waitUntilExit()
    }

    /// Install an app on the booted simulator.
    public func installApp(path: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "install", deviceId, path]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw BridgeError.simctlFailed(errMsg)
        }
    }

    public func uninstallApp(bundleId: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "uninstall", deviceId, bundleId]
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw BridgeError.simctlFailed(errMsg)
        }
    }

    public func clearState(bundleId: String) throws {
        let deviceId = try getBootedDeviceId()

        // Reset privacy permissions
        let resetProcess = Process()
        resetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        resetProcess.arguments = ["simctl", "privacy", deviceId, "reset", "all", bundleId]
        try resetProcess.run()
        resetProcess.waitUntilExit()

        // Get app data container and delete its contents.
        // dataContainerPath valida el output de simctl (#122): sin la validación,
        // "(null)" con exit 0 borraría el contenido de un directorio relativo
        // "./(null)" en el cwd del usuario. Apps sin container → skip silencioso.
        if let containerPath = try? dataContainerPath(bundleId: bundleId) {
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(atPath: containerPath) {
                for item in contents {
                    try? fm.removeItem(atPath: containerPath + "/" + item)
                }
            }
        }
    }

    // MARK: - URL / Pasteboard

    /// Open a URL in the simulator.
    public func openURL(_ url: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "openurl", deviceId, url]
        try process.run()
        process.waitUntilExit()
    }

    /// Set the pasteboard/clipboard content on the simulator.
    public func setPasteboard(text: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "pbcopy", deviceId]
        process.standardInput = pipe
        try process.run()
        pipe.fileHandleForWriting.write(text.data(using: .utf8)!)
        pipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
    }

    /// Get the pasteboard/clipboard content from the simulator.
    public func getPasteboard() throws -> String {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "pbpaste", deviceId]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - AppleScript helpers (Simulator menu)

    /// Activate Simulator and ensure it's frontmost (required for menu access).
    internal func activateSimulatorApp() {
        let workspace = NSWorkspace.shared
        if let sim = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
            sim.activate()
            usleep(500_000)
        }
    }

    /// Run an AppleScript that clicks a Simulator menu item.
    internal func clickSimulatorMenu(_ script: String) throws {
        activateSimulatorApp()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errPipe = Pipe()
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw BridgeError.appleScriptFailed(errMsg)
        }
    }

    // MARK: - Biometric (Face ID / Touch ID via Simulator menus)

    /// Idempotente: enrolla solo si no está enrollado.
    public func biometricEnroll() throws {
        if try biometricIsEnrolled() { return }
        try toggleBiometricEnrollment()
    }

    /// Idempotente: des-enrolla solo si está enrollado.
    public func biometricUnenroll() throws {
        if try !biometricIsEnrolled() { return }
        try toggleBiometricEnrollment()
    }

    /// Toggle interno — click en "Enrolled" del menú.
    private func toggleBiometricEnrollment() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Enrolled" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
        """)
    }

    public func biometricIsEnrolled() throws -> Bool {
        activateSimulatorApp()
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", """
        tell application "System Events" to tell process "Simulator"
            set enrolledItem to menu item "Enrolled" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
            set m to value of attribute "AXMenuItemMarkChar" of enrolledItem
            if m is missing value then return "false"
            return "true"
        end tell
        """]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    public func biometricMatch() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Matching Face" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
        """)
    }

    public func biometricFail() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Non-matching Face" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
        """)
    }

    // Legacy aliases
    public func faceIDEnroll() throws { try biometricEnroll() }
    public func faceIDMatch() throws { try biometricMatch() }
    public func faceIDFail() throws { try biometricFail() }
    public func faceIDIsEnrolled() throws -> Bool { try biometricIsEnrolled() }

    // MARK: - Logs / Permissions / Keychain

    public func getLogs(bundleId: String?, lines: Int) throws -> String {
        let udid = try getBootedDeviceId()
        var args = ["simctl", "spawn", udid, "log", "show",
                    "--last", "\(lines)", "--style", "compact"]
        if let bundleId = bundleId {
            let processName = bundleId.components(separatedBy: ".").last ?? bundleId
            args += ["--predicate", "process == \"\(processName)\" OR subsystem == \"\(bundleId)\""]
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        if output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return bundleId != nil
                ? "(no logs found for \(bundleId!) — app may not have run yet)"
                : "(no logs)"
        }
        return output
    }

    public func setPermission(action: String, service: String, bundleId: String) throws {
        let udid = try getBootedDeviceId()
        let validActions = ["grant", "revoke", "reset"]
        guard validActions.contains(action) else {
            throw BridgeError.simctlFailed("Invalid action '\(action)'. Use: grant, revoke, reset")
        }
        let validServices = ["camera", "microphone", "photos", "contacts", "calendars",
                             "reminders", "location", "bluetooth", "health", "homekit",
                             "notifications", "all"]
        guard validServices.contains(service) else {
            throw BridgeError.simctlFailed("Invalid service '\(service)'. Valid: \(validServices.joined(separator: ", "))")
        }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "privacy", udid, action, service, bundleId]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw BridgeError.simctlFailed(msg)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let result = String(data: data, encoding: .utf8) ?? ""
        if !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            print(result)
        }
    }

    /// Reset the booted simulator's shared keychain.
    public func resetKeychain() throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        let errPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "keychain", deviceId, "reset"]
        process.standardError = errPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8) ?? "Unknown error"
            throw BridgeError.simctlFailed(errMsg)
        }
    }

    // MARK: - Key Press / Keyboard

    public func pressKey(key: String) throws {
        _ = try getBootedDeviceId()

        switch key.lowercased() {
        case "home":
            try clickSimulatorMenu("""
            tell application "System Events" to tell process "Simulator" to click menu item "Home" of menu "Device" of menu bar 1
            """)

        case "lockbutton", "power":
            try clickSimulatorMenu("""
            tell application "System Events" to tell process "Simulator" to click menu item "Lock" of menu "Device" of menu bar 1
            """)

        case "back":
            throw BridgeError.unknown("'back' key is not applicable on iOS")

        case "enter", "delete", "tab", "escape", "volumeup", "volumedown":
            guard let pid = simulatorPID ?? findSimulatorPID() else {
                throw BridgeError.simulatorNotRunning
            }
            let keyCode: CGKeyCode
            switch key.lowercased() {
            case "enter":      keyCode = 36
            case "delete":     keyCode = 51
            case "tab":        keyCode = 48
            case "escape":     keyCode = 53
            case "volumeup":   keyCode = 72
            case "volumedown": keyCode = 73
            default:           keyCode = 53
            }
            let src = CGEventSource(stateID: .combinedSessionState)
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)

        default:
            throw BridgeError.unknown("Unknown key: '\(key)'")
        }
    }

    public func hideKeyboard() throws {
        guard let pid = simulatorPID ?? findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: false)
        keyDown?.postToPid(pid)
        keyUp?.postToPid(pid)
    }

    public func eraseText(count: Int) throws {
        guard let pid = simulatorPID ?? findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }
        let src = CGEventSource(stateID: .combinedSessionState)
        for _ in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
            keyDown?.postToPid(pid)
            keyUp?.postToPid(pid)
            usleep(30_000)
        }
    }

    // MARK: - Location / Appearance

    public func setLocation(latitude: Double, longitude: Double) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "location", deviceId, "set", "\(latitude),\(longitude)"]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.simctlFailed("Failed to set location")
        }
    }

    public func setAppearance(mode: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "ui", deviceId, "appearance", mode]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.simctlFailed("Failed to set appearance to '\(mode)'")
        }
    }

    // MARK: - Lock / Unlock / Rotate

    public func lockDevice() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Lock" of menu "Device" of menu bar 1
        """)
    }

    public func unlockDevice() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Home" of menu "Device" of menu bar 1
        """)
    }

    public func rotate(direction: String) throws {
        let menuItem: String
        switch direction {
        case "left":      menuItem = "Rotate Left"
        case "right":     menuItem = "Rotate Right"
        case "portrait":  menuItem = "Rotate Left"
        case "landscape": menuItem = "Rotate Right"
        default:
            throw BridgeError.appleScriptFailed("Invalid direction '\(direction)'. Use: left, right, portrait, landscape")
        }
        let script = """
        tell application "System Events"
            tell process "Simulator"
                tell menu bar 1
                    tell menu bar item "Device"
                        tell menu "Device"
                            click menu item "\(menuItem)"
                        end tell
                    end tell
                end tell
            end tell
        end tell
        """
        try clickSimulatorMenu(script)
    }

    // MARK: - Viewport

    public func viewport() throws -> CGRect {
        // Ensure simulatorPID is set — getSimulatorWindowFrame uses the fast
        // path and returns nil if the PID hasn't been discovered yet (e.g.
        // first call in a fresh CLI process).
        if simulatorPID == nil {
            _ = findSimulatorPID()
        }
        guard let frame = getSimulatorWindowFrame() else {
            throw BridgeError.noWindow
        }
        return frame
    }

    // MARK: - Push / Pull File

    /// Data container validado de una app. Valida el output de simctl: para
    /// apps de sistema sin container el comando puede imprimir "(null)" con
    /// exit 0 — sin esta validación se crearían (o borrarían) directorios
    /// literales "(null)/..." en el cwd (#122).
    private func dataContainerPath(bundleId: String) throws -> String {
        let deviceId = try getBootedDeviceId()
        let containerProcess = Process()
        let pipe = Pipe()
        containerProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        containerProcess.arguments = ["simctl", "get_app_container", deviceId, bundleId, "data"]
        containerProcess.standardOutput = pipe
        containerProcess.standardError = Pipe()
        try containerProcess.run()
        containerProcess.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let container = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard containerProcess.terminationStatus == 0,
              container.hasPrefix("/"),
              FileManager.default.fileExists(atPath: container) else {
            throw BridgeError.simctlFailed(
                "Could not resolve data container for '\(bundleId)' — " +
                "usa una ruta absoluta o un bundleId con data container (apps de sistema no suelen tenerlo)")
        }
        return container
    }

    /// Resuelve una ruta relativa `<bundleId>/<ruta>` a una ruta absoluta
    /// dentro del data container de la app. El segmento bundleId se descarta:
    /// `com.example.app/Documents/f.txt` → `<container>/Documents/f.txt`.
    private func resolveContainerPath(remotePath: String) throws -> String {
        let parts = remotePath.components(separatedBy: "/")
        let bundleId = parts.first ?? ""
        let relative = parts.dropFirst().joined(separator: "/")
        guard !relative.isEmpty else {
            throw BridgeError.simctlFailed(
                "remotePath debe ser '<bundleId>/<ruta>' — falta la ruta después de '\(bundleId)'")
        }
        return try dataContainerPath(bundleId: bundleId) + "/" + relative
    }

    public func pushFile(localPath: String, remotePath: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localPath) else {
            throw BridgeError.unknown("Local file not found: '\(localPath)'")
        }

        var destPath = remotePath
        if !remotePath.hasPrefix("/") {
            destPath = try resolveContainerPath(remotePath: remotePath)
        }

        // Nunca reemplazar un directorio existente — borrar Documents/ entero
        // porque el usuario omitió el nombre de archivo sería pérdida de datos
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destPath, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                throw BridgeError.unknown(
                    "Destination is a directory: '\(destPath)' — incluye el nombre de archivo en remotePath")
            }
            try fm.removeItem(atPath: destPath)
        }

        // Ensure parent directory exists
        let parentDir = (destPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        try fm.copyItem(atPath: localPath, toPath: destPath)
    }

    public func pullFile(remotePath: String, localPath: String) throws {
        let fm = FileManager.default

        var srcPath = remotePath
        if !remotePath.hasPrefix("/") {
            srcPath = try resolveContainerPath(remotePath: remotePath)
        }

        guard fm.fileExists(atPath: srcPath) else {
            throw BridgeError.unknown("Remote file not found: '\(srcPath)'")
        }

        if fm.fileExists(atPath: localPath) {
            try fm.removeItem(atPath: localPath)
        }

        // Ensure parent directory exists — localPath relativo sin directorio
        // ("pulled.txt") produce parentDir vacío y createDirectory("") lanza
        let parentDir = (localPath as NSString).deletingLastPathComponent
        if !parentDir.isEmpty {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        try fm.copyItem(atPath: srcPath, toPath: localPath)
    }
}
