import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Controls the iOS Simulator directly via macOS Accessibility APIs.
/// No XCUITest, no xcodebuild, no test runner needed.
public final class SimulatorBridge {

    private var simulatorPID: pid_t?

    public init() {}

    // MARK: - Find Simulator

    /// Finds the running Simulator.app process.
    public func findSimulator() throws -> AXUIElement {
        let workspace = NSWorkspace.shared
        guard let simApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else {
            throw BridgeError.simulatorNotRunning
        }

        simulatorPID = simApp.processIdentifier
        return AXUIElementCreateApplication(simApp.processIdentifier)
    }

    // MARK: - Accessibility Tree

    /// Returns the full accessibility tree of the frontmost simulator window.
    public func tree(element: AXUIElement? = nil) throws -> [[String: Any]] {
        let root = try element.map { $0 } ?? findSimulatorContent()
        return serializeChildren(of: root, depth: 0, maxDepth: 20)
    }

    /// Searches elements matching a query.
    public func search(query: String) throws -> [[String: Any]] {
        let root = try findSimulatorContent()
        var results: [[String: Any]] = []
        searchRecursive(element: root, query: query.lowercased(), results: &results, depth: 0, maxDepth: 20)
        return results
    }

    /// Finds the element at a screen coordinate (relative to simulator content).
    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        let root = try findSimulatorContent()
        let point = CGPoint(x: x, y: y)
        return findElementAt(point: point, in: root, depth: 0)
    }

    // MARK: - Actions

    /// Taps an element using AX press action (native accessibility tap).
    public func tap(target: String) throws {
        let root = try findSimulatorContent()
        guard let axElement = findAXElement(in: root, matching: target, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound(target)
        }

        let result = AXUIElementPerformAction(axElement, kAXPressAction as CFString)
        guard result == .success else {
            // Fallback: try click at element center
            let info = serializeElement(axElement)
            guard let position = info["_position"] as? CGPoint,
                  let size = info["_size"] as? CGSize else {
                throw BridgeError.noFrame(target)
            }
            let center = CGPoint(
                x: position.x + size.width / 2,
                y: position.y + size.height / 2
            )
            try click(at: center)
            return
        }
    }

    /// Long press an element for a duration (default 1 second).
    public func longPress(target: String, duration: Double = 1.0) throws {
        let root = try findSimulatorContent()
        guard let axElement = findAXElement(in: root, matching: target, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound(target)
        }

        let info = serializeElement(axElement)
        guard let position = info["_position"] as? CGPoint,
              let size = info["_size"] as? CGSize else {
            throw BridgeError.noFrame(target)
        }

        let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        let src = CGEventSource(stateID: .combinedSessionState)

        let mouseDown = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: center, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        usleep(UInt32(duration * 1_000_000))
        let mouseUp = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: center, mouseButton: .left)
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Double-tap an element.
    public func doubleTap(target: String) throws {
        let root = try findSimulatorContent()
        guard let axElement = findAXElement(in: root, matching: target, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound(target)
        }
        AXUIElementPerformAction(axElement, kAXPressAction as CFString)
        usleep(100_000)
        AXUIElementPerformAction(axElement, kAXPressAction as CFString)
    }

    /// Clear a text field: tap it, select all (Cmd+A), then delete.
    public func clear(target: String) throws {
        try tap(target: target)
        usleep(200_000)

        guard let pid = simulatorPID ?? findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }

        let src = CGEventSource(stateID: .combinedSessionState)

        // Cmd+A (select all)
        let aDown = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true) // 0 = 'a'
        let aUp = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false)
        aDown?.flags = .maskCommand
        aUp?.flags = .maskCommand
        aDown?.postToPid(pid)
        aUp?.postToPid(pid)
        usleep(100_000)

        // Delete
        let delDown = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true) // 51 = delete
        let delUp = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false)
        delDown?.postToPid(pid)
        delUp?.postToPid(pid)
    }

    /// Type text by sending keyboard events to the Simulator.
    public func typeText(_ text: String) throws {
        guard let pid = simulatorPID ?? findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }

        // Bring simulator to front
        let simApp = NSRunningApplication(processIdentifier: pid)
        simApp?.activate()
        usleep(200_000)

        let src = CGEventSource(stateID: .combinedSessionState)

        for char in text {
            if let keyCode = keyCodeForChar(char) {
                let needsShift = char.isUppercase || shiftChars.contains(char)

                let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
                let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)

                if needsShift {
                    keyDown?.flags = .maskShift
                    keyUp?.flags = .maskShift
                }

                keyDown?.postToPid(pid)
                keyUp?.postToPid(pid)
                usleep(30_000) // 30ms between keys
            }
        }
    }

    /// Scroll within a specific element.
    public func scroll(target: String, direction: String) throws {
        let root = try findSimulatorContent()
        guard let axElement = findAXElement(in: root, matching: target, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound(target)
        }

        let info = serializeElement(axElement)
        guard let position = info["_position"] as? CGPoint,
              let size = info["_size"] as? CGSize else {
            throw BridgeError.noFrame(target)
        }

        let centerX = position.x + size.width / 2
        let centerY = position.y + size.height / 2
        let distance: CGFloat = min(size.height * 0.4, 200)

        let (startPoint, endPoint): (CGPoint, CGPoint)
        switch direction.lowercased() {
        case "up":
            startPoint = CGPoint(x: centerX, y: centerY + distance / 2)
            endPoint = CGPoint(x: centerX, y: centerY - distance / 2)
        case "down":
            startPoint = CGPoint(x: centerX, y: centerY - distance / 2)
            endPoint = CGPoint(x: centerX, y: centerY + distance / 2)
        case "left":
            startPoint = CGPoint(x: centerX + distance / 2, y: centerY)
            endPoint = CGPoint(x: centerX - distance / 2, y: centerY)
        case "right":
            startPoint = CGPoint(x: centerX - distance / 2, y: centerY)
            endPoint = CGPoint(x: centerX + distance / 2, y: centerY)
        default:
            throw BridgeError.invalidDirection(direction)
        }

        let src = CGEventSource(stateID: .combinedSessionState)

        let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: startPoint, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        usleep(50_000)

        let mouseDown = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        usleep(100_000)

        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = startPoint.x + (endPoint.x - startPoint.x) * t
            let y = startPoint.y + (endPoint.y - startPoint.y) * t
            let drag = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            usleep(15_000)
        }

        let mouseUp = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left)
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Scroll/swipe using mouse drag events posted globally.
    /// Simulates a finger drag on the Simulator touchscreen area.
    public func swipe(direction: String) throws {
        guard let pid = simulatorPID ?? findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }

        // Activate simulator
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
            usleep(300_000)
        }

        // Get simulator window for positioning
        let simApp = try findSimulator()
        guard let window = getFirstWindow(of: simApp),
              let pos = getPosition(of: window),
              let size = getSize(of: window) else {
            throw BridgeError.noWindow
        }

        let centerX = pos.x + size.width / 2
        let centerY = pos.y + size.height / 2
        let distance: CGFloat = 200

        let (startPoint, endPoint): (CGPoint, CGPoint)
        switch direction.lowercased() {
        case "up":
            startPoint = CGPoint(x: centerX, y: centerY + distance / 2)
            endPoint = CGPoint(x: centerX, y: centerY - distance / 2)
        case "down":
            startPoint = CGPoint(x: centerX, y: centerY - distance / 2)
            endPoint = CGPoint(x: centerX, y: centerY + distance / 2)
        case "left":
            startPoint = CGPoint(x: centerX + distance / 2, y: centerY)
            endPoint = CGPoint(x: centerX - distance / 2, y: centerY)
        case "right":
            startPoint = CGPoint(x: centerX - distance / 2, y: centerY)
            endPoint = CGPoint(x: centerX + distance / 2, y: centerY)
        default:
            throw BridgeError.invalidDirection(direction)
        }

        // Use global posting for drag events
        let src = CGEventSource(stateID: .combinedSessionState)

        // Move to start position
        let move = CGEvent(mouseEventSource: src, mouseType: .mouseMoved, mouseCursorPosition: startPoint, mouseButton: .left)
        move?.post(tap: .cghidEventTap)
        usleep(50_000)

        // Mouse down
        let mouseDown = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: startPoint, mouseButton: .left)
        mouseDown?.post(tap: .cghidEventTap)
        usleep(100_000)

        // Drag in small increments — Simulator needs smooth movement to register as iOS swipe
        let steps = 20
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let x = startPoint.x + (endPoint.x - startPoint.x) * t
            let y = startPoint.y + (endPoint.y - startPoint.y) * t
            let drag = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            usleep(15_000)
        }

        // Mouse up
        let mouseUp = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: endPoint, mouseButton: .left)
        mouseUp?.post(tap: .cghidEventTap)
    }

    /// Take a screenshot using simctl.
    public func screenshot(path: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", deviceId, "screenshot", path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.screenshotFailed
        }
    }

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

    /// Inject media (photo/video) into the simulator's photo library.
    public func addMedia(path: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "addmedia", deviceId, path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.mediaInjectionFailed(path)
        }
    }

    // MARK: - Face ID / Biometry (via Simulator menu + AppleScript)

    /// Activate Simulator and ensure it's frontmost (required for menu access).
    private func activateSimulatorApp() {
        let workspace = NSWorkspace.shared
        if let sim = workspace.runningApplications.first(where: { $0.bundleIdentifier == "com.apple.iphonesimulator" }) {
            sim.activate()
            usleep(500_000)
        }
    }

    /// Run an AppleScript that clicks a Simulator menu item.
    private func clickSimulatorMenu(_ script: String) throws {
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

    /// Enroll or unenroll Face ID on the simulator.
    public func faceIDEnroll() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Enrolled" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
        """)
    }

    /// Check if Face ID is currently enrolled.
    public func faceIDIsEnrolled() throws -> Bool {
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

    /// Simulate a successful Face ID scan.
    public func faceIDMatch() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Matching Face" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
        """)
    }

    /// Simulate a failed Face ID scan.
    public func faceIDFail() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Non-matching Face" of menu "Face ID" of menu item "Face ID" of menu "Features" of menu bar 1
        """)
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

    /// Open a URL in the simulator.
    public func openURL(_ url: String) throws {
        let deviceId = try getBootedDeviceId()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "openurl", deviceId, url]
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - Virtual Camera

    private let cameraFeedPath = "/tmp/autopilot-camera-feed.jpg"
    private let cameraSignalPath = "/tmp/autopilot-camera-active"

    /// Start virtual camera with an image.
    public func cameraStart(imagePath: String) throws {
        let source = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw BridgeError.cameraImageNotFound(imagePath)
        }

        let dest = URL(fileURLWithPath: cameraFeedPath)
        if FileManager.default.fileExists(atPath: cameraFeedPath) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)

        // Crear archivo signal
        FileManager.default.createFile(atPath: cameraSignalPath, contents: nil)
    }

    /// Update the camera feed image.
    public func cameraFeed(imagePath: String) throws {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw BridgeError.cameraImageNotFound(imagePath)
        }

        let dest = URL(fileURLWithPath: cameraFeedPath)
        if FileManager.default.fileExists(atPath: cameraFeedPath) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: imagePath), to: dest)
    }

    /// Stop the virtual camera.
    public func cameraStop() {
        try? FileManager.default.removeItem(atPath: cameraSignalPath)
        try? FileManager.default.removeItem(atPath: cameraFeedPath)
    }

    /// Check if virtual camera is active.
    public func cameraStatus() -> (active: Bool, imagePath: String?) {
        let active = FileManager.default.fileExists(atPath: cameraSignalPath)
        let hasImage = FileManager.default.fileExists(atPath: cameraFeedPath)
        return (active: active, imagePath: hasImage ? cameraFeedPath : nil)
    }

    // MARK: - Private: Simulator access

    private func findSimulatorPID() -> pid_t? {
        let workspace = NSWorkspace.shared
        guard let simApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else { return nil }
        simulatorPID = simApp.processIdentifier
        return simApp.processIdentifier
    }

    private func findSimulatorContent() throws -> AXUIElement {
        // Re-discover the Simulator process each time (handles PID changes)
        let workspace = NSWorkspace.shared
        guard let simRunning = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else {
            throw BridgeError.simulatorNotRunning
        }

        simulatorPID = simRunning.processIdentifier

        // Activate to make AX tree available
        simRunning.activate()

        let app = AXUIElementCreateApplication(simRunning.processIdentifier)

        // Retry getting window — AX tree needs time after activation
        for _ in 0..<15 {
            if let window = getFirstWindow(of: app) {
                // Verify the window has children (fully loaded)
                if let children = getChildren(of: window), !children.isEmpty {
                    return window
                }
            }
            usleep(200_000)
        }

        throw BridgeError.noWindow
    }

    private func getFirstWindow(of app: AXUIElement) -> AXUIElement? {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard let windowArray = windows as? [AXUIElement], let first = windowArray.first else {
            return nil
        }
        return first
    }

    private func getPosition(of element: AXUIElement) -> CGPoint? {
        var posValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        guard let val = posValue else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &point)
        return point
    }

    private func getSize(of element: AXUIElement) -> CGSize? {
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard let val = sizeValue else { return nil }
        var size = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &size)
        return size
    }

    /// Tap at absolute screen coordinates using global event posting.
    /// Works for system UIs (photo picker, alerts) where postToPid doesn't reach.
    public func tapAtCoordinate(x: Double, y: Double) throws {
        let point = CGPoint(x: x, y: y)
        let src = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        // Post globally instead of to a specific PID — reaches system UIs
        mouseDown?.post(tap: .cghidEventTap)
        usleep(80_000)
        mouseUp?.post(tap: .cghidEventTap)
    }

    // MARK: - Private: Click

    private func click(at point: CGPoint) throws {
        guard let pid = simulatorPID ?? findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }

        let src = CGEventSource(stateID: .combinedSessionState)
        let mouseDown = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let mouseUp = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)

        mouseDown?.postToPid(pid)
        usleep(50_000)
        mouseUp?.postToPid(pid)
    }

    // MARK: - Private: Serialization

    private func serializeElement(_ element: AXUIElement) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["role"] = getAttribute(element, kAXRoleAttribute) as? String ?? "Unknown"
        dict["title"] = getAttribute(element, kAXTitleAttribute) as? String ?? ""
        dict["value"] = getAttribute(element, kAXValueAttribute) as? String ?? ""
        dict["label"] = getAttribute(element, kAXDescriptionAttribute) as? String ?? ""
        dict["identifier"] = getAttribute(element, "AXIdentifier") as? String ?? ""

        if let pos = getPosition(of: element), let size = getSize(of: element) {
            dict["frame"] = [
                "x": Int(pos.x), "y": Int(pos.y),
                "width": Int(size.width), "height": Int(size.height)
            ]
            dict["_position"] = pos
            dict["_size"] = size
        }

        let enabled = getAttribute(element, kAXEnabledAttribute) as? Bool ?? true
        dict["enabled"] = enabled

        return dict
    }

    private func serializeChildren(of element: AXUIElement, depth: Int, maxDepth: Int) -> [[String: Any]] {
        guard depth < maxDepth else { return [] }

        var result: [[String: Any]] = []
        guard let children = getChildren(of: element) else { return [] }

        for child in children {
            let info = serializeElement(child)
            // Remove internal keys
            var clean = info
            clean.removeValue(forKey: "_position")
            clean.removeValue(forKey: "_size")

            let childElements = serializeChildren(of: child, depth: depth + 1, maxDepth: maxDepth)
            if !childElements.isEmpty {
                clean["children"] = childElements
            }
            result.append(clean)
        }
        return result
    }

    private func searchRecursive(element: AXUIElement, query: String, results: inout [[String: Any]], depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        guard let children = getChildren(of: element) else { return }

        for child in children {
            let info = serializeElement(child)
            let role = (info["role"] as? String ?? "").lowercased()
            let title = (info["title"] as? String ?? "").lowercased()
            let label = (info["label"] as? String ?? "").lowercased()
            let identifier = (info["identifier"] as? String ?? "").lowercased()
            let value = (info["value"] as? String ?? "").lowercased()

            if role.contains(query) || title.contains(query) || label.contains(query)
                || identifier.contains(query) || value.contains(query) {
                var clean = info
                clean.removeValue(forKey: "_position")
                clean.removeValue(forKey: "_size")
                results.append(clean)
            }

            searchRecursive(element: child, query: query, results: &results, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// Finds the raw AXUIElement matching target (for performing actions).
    /// Priority: exact match (all depths) → contains match (all depths)
    private func findAXElement(in element: AXUIElement, matching target: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        let lowered = target.lowercased()

        // 1. Exact match at this level
        for child in children {
            let title = (getAttribute(child, kAXTitleAttribute) as? String ?? "").lowercased()
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            let identifier = (getAttribute(child, "AXIdentifier") as? String ?? "").lowercased()
            let value = (getAttribute(child, kAXValueAttribute) as? String ?? "").lowercased()

            if identifier == lowered || title == lowered || label == lowered || value == lowered {
                return child
            }
        }

        // 2. Recurse for exact match at deeper levels BEFORE contains match
        for child in children {
            if let found = findAXElementExact(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }

        // 3. Contains match — only on label (description), prefer shorter (more specific)
        var containsMatch: (element: AXUIElement, length: Int)?
        for child in children {
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            if !label.isEmpty && label.contains(lowered) {
                let len = label.count
                if containsMatch == nil || len < containsMatch!.length {
                    containsMatch = (child, len)
                }
            }
        }
        if let match = containsMatch {
            return match.element
        }

        // 4. Recurse for contains match at deeper levels
        for child in children {
            if let found = findAXElementContains(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }

        return nil
    }

    /// Exact-only recursive search (used as priority pass).
    private func findAXElementExact(in element: AXUIElement, matching lowered: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        for child in children {
            let title = (getAttribute(child, kAXTitleAttribute) as? String ?? "").lowercased()
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            let identifier = (getAttribute(child, "AXIdentifier") as? String ?? "").lowercased()
            let value = (getAttribute(child, kAXValueAttribute) as? String ?? "").lowercased()

            if identifier == lowered || title == lowered || label == lowered || value == lowered {
                return child
            }
        }

        for child in children {
            if let found = findAXElementExact(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Contains-only recursive search (used as fallback pass).
    private func findAXElementContains(in element: AXUIElement, matching lowered: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        var best: (element: AXUIElement, length: Int)?
        for child in children {
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            if !label.isEmpty && label.contains(lowered) {
                let len = label.count
                if best == nil || len < best!.length {
                    best = (child, len)
                }
            }
        }
        if let match = best {
            return match.element
        }

        for child in children {
            if let found = findAXElementContains(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func findElementInfo(in element: AXUIElement, matching target: String, depth: Int, maxDepth: Int) -> [String: Any]? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        let lowered = target.lowercased()

        // First pass: exact match on any field
        for child in children {
            let info = serializeElement(child)
            let title = (info["title"] as? String ?? "").lowercased()
            let label = (info["label"] as? String ?? "").lowercased()
            let identifier = (info["identifier"] as? String ?? "").lowercased()
            let value = (info["value"] as? String ?? "").lowercased()

            if identifier == lowered || title == lowered || label == lowered || value == lowered {
                return info
            }
        }

        // Second pass: partial match (description often has long text like "General, ...")
        for child in children {
            let info = serializeElement(child)
            let label = (info["label"] as? String ?? "").lowercased()

            if label.hasPrefix(lowered) || label.contains(", \(lowered)") {
                return info
            }
        }

        // Recurse into children
        for child in children {
            if let found = findElementInfo(in: child, matching: target, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func findElementAt(point: CGPoint, in element: AXUIElement, depth: Int) -> [String: Any]? {
        guard depth < 20 else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        var best: [String: Any]?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for child in children {
            guard let pos = getPosition(of: child), let size = getSize(of: child) else { continue }
            let frame = CGRect(origin: pos, size: size)

            if frame.contains(point) {
                let area = size.width * size.height
                if area < bestArea {
                    bestArea = area
                    var info = serializeElement(child)
                    info.removeValue(forKey: "_position")
                    info.removeValue(forKey: "_size")
                    best = info
                }
                if let deeper = findElementAt(point: point, in: child, depth: depth + 1) {
                    return deeper
                }
            }
        }
        return best
    }

    // MARK: - Private: AX helpers

    private func getAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value
    }

    private func getChildren(of element: AXUIElement) -> [AXUIElement]? {
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        return children as? [AXUIElement]
    }

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

    // MARK: - Private: Key mapping

    private let shiftChars: Set<Character> = Set("~!@#$%^&*()_+{}|:\"<>?")

    private func keyCodeForChar(_ char: Character) -> CGKeyCode? {
        let lower = char.lowercased()
        let map: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
        ]
        if lower == "\n" || lower == "\r" { return 36 }
        if lower == "\t" { return 48 }
        return map[lower]
    }

    // MARK: - Build

    /// Builds an Xcode project with camera mock injected via VFS overlay.
    public func buildWithCameraMock(args: [String]) throws {
        let interceptor = BuildInterceptor()
        try interceptor.build(args: args)
    }
}

// MARK: - Errors

public enum BridgeError: Error, CustomStringConvertible {
    case simulatorNotRunning
    case noWindow
    case elementNotFound(String)
    case noFrame(String)
    case noBootedDevice
    case invalidDirection(String)
    case screenshotFailed
    case mediaInjectionFailed(String)
    case appleScriptFailed(String)
    case simctlFailed(String)
    case deviceNotFound(String)
    case cameraImageNotFound(String)

    public var description: String {
        switch self {
        case .simulatorNotRunning: return "Simulator is not running. Open it first."
        case .noWindow: return "No simulator window found"
        case .elementNotFound(let t): return "Element not found: '\(t)'"
        case .noFrame(let t): return "Element '\(t)' has no frame"
        case .noBootedDevice: return "No booted simulator. Run: xcrun simctl boot <device>"
        case .invalidDirection(let d): return "Invalid direction: \(d). Use up/down/left/right"
        case .screenshotFailed: return "Screenshot failed"
        case .mediaInjectionFailed(let p): return "Failed to inject media: \(p)"
        case .appleScriptFailed(let msg): return "AppleScript failed: \(msg)"
        case .simctlFailed(let msg): return "simctl failed: \(msg)"
        case .deviceNotFound(let name): return "Device not found: '\(name)'. Run: auto list"
        case .cameraImageNotFound(let p): return "Image not found: '\(p)'"
        }
    }
}
