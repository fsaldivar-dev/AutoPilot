import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import AutoCore

/// Controls the iOS Simulator directly via macOS Accessibility APIs.
/// No XCUITest, no xcodebuild, no test runner needed.
public final class SimulatorBridge {

    private var simulatorPID: pid_t?
    private var recordingProcess: Process?
    private var recordingTempPath: String?

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

    // MARK: - Post-tap verification tuning (issue #80)
    //
    // `AXUIElementPerformAction` can report success without the event actually
    // reaching the app (Simulator-level intercept, app mid-transition, etc.).
    // Skip the check on the happy path — a blocking action means the sim was
    // processing and the tap almost certainly landed. Only when the action
    // returns suspiciously fast do we pay for a fingerprint diff + wait +
    // retry via CGEvent.
    private static let axTrustThresholdMs = 40
    private static let fastSettleUs: UInt32 = 80_000
    private static let extendedSettleUs: UInt32 = 120_000

    /// Taps an element using AX press action (native accessibility tap).
    public func tap(target: String) throws {
        let root = try findSimulatorContent()
        guard let axElement = findAXElement(in: root, matching: target, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound(target)
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        let actionStart = CFAbsoluteTimeGetCurrent()
        let axResult = AXUIElementPerformAction(axElement, kAXPressAction as CFString)
        let actionMs = elapsedMs(actionStart)

        if axResult != .success {
            let center = try resolveElementCenter(axElement, target: target)
            try click(at: center)
            logTap(target: target, path: "cgevent-direct", t0: t0, actionMs: actionMs, changed: nil)
            return
        }

        // Happy path: AXAction blocked on UI work. Trust it.
        if actionMs >= Self.axTrustThresholdMs {
            logTap(target: target, path: "axaction-fast", t0: t0, actionMs: actionMs, changed: nil)
            return
        }

        // Suspicious: action returned instantly. Diff a fingerprint before/after.
        let preFingerprint = ViewFingerprint.capture(root: root)
        usleep(Self.fastSettleUs)
        if ViewFingerprint.capture(root: root) != preFingerprint {
            logTap(target: target, path: "axaction-verified", t0: t0, actionMs: actionMs, changed: true)
            return
        }

        // Extended confirm: slower transitions still count as success.
        usleep(Self.extendedSettleUs)
        if ViewFingerprint.capture(root: root) != preFingerprint {
            logTap(target: target, path: "axaction-slow", t0: t0, actionMs: actionMs, changed: true)
            return
        }

        // Silent drop confirmed: retry via CGEvent at element center.
        let center = try resolveElementCenter(axElement, target: target)
        try click(at: center)
        logTap(target: target, path: "axaction-silent→cgevent", t0: t0, actionMs: actionMs, changed: false)
    }

    private func resolveElementCenter(_ axElement: AXUIElement, target: String) throws -> CGPoint {
        let info = serializeElement(axElement)
        guard let pos = info["_position"] as? CGPoint, let size = info["_size"] as? CGSize else {
            throw BridgeError.noFrame(target)
        }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    private func logTap(target: String, path: String, t0: CFAbsoluteTime, actionMs: Int, changed: Bool?) {
        let changedStr = changed.map { $0 ? "changed" : "no-change" } ?? "unchecked"
        debugTimingLog("tap target=\(target) path=\(path) actionMs=\(actionMs) elapsed=\(elapsedMs(t0))ms ui=\(changedStr)")
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

    /// Characters that are unreliable through CGEvent + shift modifier
    /// (postToPid drops these intermittently, especially `+`, `@`, `!`, `#`, `$`).
    /// When the input contains any of these we route the entire string through
    /// the simulator pasteboard + Cmd+V for a deterministic paste.
    private static let trickyTypeChars: Set<Character> = [
        "+", "@", "!", "#", "$", "%", "^", "&", "*",
        "(", ")", "_", "{", "}", "|", ":", "\"",
        "<", ">", "?", "~", "`"
    ]

    /// Type text by sending keyboard events to the Simulator.
    /// If the text contains characters that drop unreliably with CGEvent shift
    /// (`+`, `@`, `!`, ...), the whole string is pasted via `simctl pbcopy` + Cmd+V.
    public func typeText(_ text: String) throws {
        guard let pid = simulatorPID ?? findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }

        // Make sure Connect Hardware Keyboard is enabled, otherwise CGEvents
        // posted to the simulator process are silently dropped.
        ensureHardwareKeyboardEnabled()

        // Bring simulator to front
        let simApp = NSRunningApplication(processIdentifier: pid)
        simApp?.activate()
        usleep(200_000)

        // Strategy for tricky chars (`+`, `@`, `!`, ...):
        //   1. AX setvalue on the focused element (silent, instant). Often fails
        //      on iOS app fields because focus lives inside the iframe.
        //   2. simctl pbcopy + Cmd+V via osascript. This path is independent
        //      of keyboard layout (US/Latin American/etc) but triggers the iOS 17+
        //      pasteboard privacy dialog. We auto-dismiss that dialog by tapping
        //      "Permitir pegar" / "Allow Paste" right after the paste.
        //   3. (intentionally no char-by-char fallback: per-key CGEvents with
        //      shift modifiers depend on the macOS keyboard layout, which on
        //      Latin American layouts maps shift+2 to `"` instead of `@`,
        //      shift+= to garbage instead of `+`, etc.)
        if text.contains(where: { Self.trickyTypeChars.contains($0) }) {
            if trySetFocusedFieldValue(text) {
                return
            }
            try pasteViaPasteboard(text, pid: pid)
            autoDismissPasteboardDialog()
            return
        }

        let src = CGEventSource(stateID: .combinedSessionState)
        let shiftKeyCode: CGKeyCode = 56 // left shift

        for char in text {
            guard let keyCode = keyCodeForChar(char) else { continue }
            let needsShift = char.isUppercase || shiftChars.contains(char)

            let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)

            // iOS Simulator does not reliably honor `flags = .maskShift` on a
            // single CGEvent. Post explicit shift down → key → shift up instead.
            if needsShift {
                let shiftDown = CGEvent(keyboardEventSource: src, virtualKey: shiftKeyCode, keyDown: true)
                let shiftUp = CGEvent(keyboardEventSource: src, virtualKey: shiftKeyCode, keyDown: false)
                keyDown?.flags = .maskShift
                keyUp?.flags = .maskShift
                shiftDown?.postToPid(pid)
                usleep(5_000)
                keyDown?.postToPid(pid)
                keyUp?.postToPid(pid)
                shiftUp?.postToPid(pid)
            } else {
                keyDown?.postToPid(pid)
                keyUp?.postToPid(pid)
            }
            usleep(30_000) // 30ms between keys
        }
    }

    /// Walks the simulator AX tree to find the currently focused element and
    /// sets its AXValue to `text`. Returns `true` on success, `false` if there
    /// is no focused element, no settable AXValue, or any AX call fails.
    /// This is the most reliable path for password fields that disable paste.
    private func trySetFocusedFieldValue(_ text: String) -> Bool {
        guard let pid = simulatorPID ?? findSimulatorPID() else { return false }
        let app = AXUIElementCreateApplication(pid)

        var focusedAny: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedAny)
        guard focusedResult == .success, let focused = focusedAny, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return false
        }
        let focusedEl = focused as! AXUIElement

        var settable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(focusedEl, kAXValueAttribute as CFString, &settable)
        guard settableResult == .success, settable.boolValue else {
            return false
        }

        let setResult = AXUIElementSetAttributeValue(focusedEl, kAXValueAttribute as CFString, text as CFTypeRef)
        return setResult == .success
    }

    /// Toggles `Simulator → I/O → Keyboard → Connect Hardware Keyboard` ON
    /// if it is currently OFF. Without this, CGEvents posted to the simulator
    /// process are silently dropped. Idempotent — does nothing when already ON.
    private func ensureHardwareKeyboardEnabled() {
        let script = """
        tell application "System Events"
            tell process "Simulator"
                try
                    set markVal to value of attribute "AXMenuItemMarkChar" of menu item "Connect Hardware Keyboard" of menu 1 of menu item "Keyboard" of menu 1 of menu bar item "I/O" of menu bar 1
                    if markVal is missing value then
                        click menu item "Connect Hardware Keyboard" of menu 1 of menu item "Keyboard" of menu 1 of menu bar item "I/O" of menu bar 1
                    end if
                end try
            end tell
        end tell
        """
        let proc = Process()
        proc.launchPath = "/usr/bin/osascript"
        proc.arguments = ["-e", script]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            // Best-effort: if AppleScript fails (no AX permissions, simulator
            // not at front, etc.) we still try the type — the user gets a clear
            // empty-field symptom rather than a crash here.
        }
    }

    /// Copies `text` to the booted simulator pasteboard via `xcrun simctl pbcopy`
    /// and then sends Cmd+V to the Simulator via osascript keystroke (the
    /// CGEvent path is unreliable for Cmd+V into the simulator window).
    /// If the focused field rejects paste (e.g. some password fields), the
    /// caller should fall back to per-character typing.
    /// Throws on pbcopy failure; the paste keystroke itself is best-effort.
    private func pasteViaPasteboard(_ text: String, pid: pid_t) throws {
        // 1. Pipe `text` into `xcrun simctl pbcopy booted`
        let pbcopy = Process()
        pbcopy.launchPath = "/usr/bin/xcrun"
        pbcopy.arguments = ["simctl", "pbcopy", "booted"]
        let stdinPipe = Pipe()
        pbcopy.standardInput = stdinPipe
        pbcopy.standardOutput = Pipe()
        pbcopy.standardError = Pipe()
        try pbcopy.run()
        if let data = text.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()
        pbcopy.waitUntilExit()
        guard pbcopy.terminationStatus == 0 else {
            throw BridgeError.appleScriptFailed("simctl pbcopy failed (status=\(pbcopy.terminationStatus))")
        }

        // 2. Bring Simulator to front and Cmd+V via System Events. This is the
        // path that actually triggers iOS Paste; CGEvent postToPid does not.
        let script = """
        tell application "Simulator" to activate
        delay 0.4
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """
        let osa = Process()
        osa.launchPath = "/usr/bin/osascript"
        osa.arguments = ["-e", script]
        osa.standardOutput = Pipe()
        osa.standardError = Pipe()
        try? osa.run()
        osa.waitUntilExit()
        usleep(200_000)
    }

    /// After a `pasteViaPasteboard` call, iOS 17+ shows a privacy dialog asking
    /// the user to allow paste from CoreSimulatorBridge. The dialog IS in the
    /// Simulator AX tree (unlike Save Password), so we can find and tap
    /// "Permitir pegar" / "Allow Paste" automatically. No-op if the dialog
    /// is not present (iOS may have remembered the previous answer).
    private func autoDismissPasteboardDialog() {
        usleep(300_000) // give iOS a moment to render the dialog
        guard let root = try? findSimulatorContent() else { return }
        let candidateLabels = ["Permitir pegar", "Allow Paste", "Allow"]
        for label in candidateLabels {
            if let element = findAXElement(in: root, matching: label, depth: 0, maxDepth: 12) {
                tapElement(element)
                usleep(150_000)
                return
            }
        }
    }

    /// Per-character typing using CGEvent keycodes. This is the original
    /// reliable path for plain ASCII letters/digits/space. Used as a fallback
    /// when the field rejects paste (some password fields disable Cmd+V).
    private func typeCharByChar(_ text: String, pid: pid_t) {
        let src = CGEventSource(stateID: .combinedSessionState)
        for char in text {
            if let keyCode = keyCodeForChar(char) {
                let needsShift = char.isUppercase || shiftChars.contains(char)
                let keyDown = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true)
                let keyUp   = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false)
                if needsShift {
                    keyDown?.flags = .maskShift
                    keyUp?.flags   = .maskShift
                }
                keyDown?.postToPid(pid)
                keyUp?.postToPid(pid)
                usleep(30_000)
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

    public func findSimulatorPID() -> pid_t? {
        let workspace = NSWorkspace.shared
        guard let simApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else { return nil }
        simulatorPID = simApp.processIdentifier
        return simApp.processIdentifier
    }

    public func findSimulatorContent() throws -> AXUIElement {
        // Re-discover the Simulator process each time (handles PID changes)
        let workspace = NSWorkspace.shared
        guard let simRunning = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else {
            throw BridgeError.simulatorNotRunning
        }

        simulatorPID = simRunning.processIdentifier

        // Activate to make AX tree available (ignoring other apps ensures
        // it works even when launched from editor/Tauri subprocesses)
        simRunning.activate(options: .activateIgnoringOtherApps)

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

        // If we got here, check if it's a permissions issue
        if !AXIsProcessTrusted() {
            throw BridgeError.accessibilityNotTrusted
        }
        throw BridgeError.noWindow
    }

    /// Lightweight content access — skips activation and retries.
    /// Use during recording when Simulator is already in the foreground.
    /// Get the Simulator window frame in screen coordinates.
    public func getSimulatorWindowFrame() -> CGRect? {
        guard let window = findSimulatorContentFast() else { return nil }
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    public func findSimulatorContentFast() -> AXUIElement? {
        guard let pid = simulatorPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        return getFirstWindow(of: app)
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

    // MARK: - Drag

    public func drag(from: String, to: String, duration: Double) throws {
        let root = try findSimulatorContent()
        guard let fromEl = findAXElement(in: root, matching: from, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound("Could not find '\(from)' for drag")
        }
        guard let toEl = findAXElement(in: root, matching: to, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound("Could not find '\(to)' for drag")
        }
        let fromInfo = serializeElement(fromEl)
        let toInfo = serializeElement(toEl)
        guard let fromPos = fromInfo["_position"] as? CGPoint,
              let fromSize = fromInfo["_size"] as? CGSize,
              let toPos = toInfo["_position"] as? CGPoint,
              let toSize = toInfo["_size"] as? CGSize else {
            throw BridgeError.noFrame("\(from) or \(to)")
        }
        let fromCenter = CGPoint(x: fromPos.x + fromSize.width / 2,
                                 y: fromPos.y + fromSize.height / 2)
        let toCenter = CGPoint(x: toPos.x + toSize.width / 2,
                               y: toPos.y + toSize.height / 2)
        try dragCoordinates(x1: Double(fromCenter.x), y1: Double(fromCenter.y),
                            x2: Double(toCenter.x), y2: Double(toCenter.y),
                            duration: duration)
    }

    public func dragCoordinates(x1: Double, y1: Double, x2: Double, y2: Double, duration: Double) throws {
        let from = CGPoint(x: x1, y: y1)
        let to = CGPoint(x: x2, y: y2)
        let steps = max(10, Int(duration * 60))
        let stepDelay = duration / Double(steps)

        let src = CGEventSource(stateID: .combinedSessionState)

        // Mouse down
        let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                           mouseCursorPosition: from, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)

        // Drag steps
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let x = x1 + (x2 - x1) * t
            let y = y1 + (y2 - y1) * t
            let pos = CGPoint(x: x, y: y)
            let drag = CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
                               mouseCursorPosition: pos, mouseButton: .left)
            drag?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: stepDelay)
        }

        // Mouse up
        let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                         mouseCursorPosition: to, mouseButton: .left)
        up?.post(tap: .cghidEventTap)
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

    // MARK: - Tap Element (raw AXUIElement)

    /// Tap a resolved AXUIElement directly (AXPress with click fallback).
    public func tapElement(_ element: AXUIElement) {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result != .success {
            if let pos = getPosition(of: element), let size = getSize(of: element) {
                let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                try? click(at: center)
            }
        }
    }

    // MARK: - Scoped Element Search (role + within)

    /// Find element with optional role filtering and scope.
    /// Fallback chain: role+scope → scope only → global → error
    public func findAXElementScoped(target: String, role: String? = nil, within: String? = nil) throws -> AXUIElement {
        let root = try findSimulatorContent()

        // Resolve scope element
        var scopeElement: AXUIElement? = nil
        if let within {
            scopeElement = findAXElement(in: root, matching: within, depth: 0, maxDepth: 20)
            if scopeElement == nil {
                fputs("[within] '\(within)' not found, searching globally\n", stderr)
            }
        }

        // Parse label[N] from target
        let (label, occurrence) = TargetResolver.parse(target)

        // Search with role + scope
        let matches = TargetResolver.findAll(in: root, matching: label, scope: scopeElement, requiredRole: role)

        if let occurrence {
            if occurrence >= 1 && occurrence <= matches.count {
                return matches[occurrence - 1].element
            }
            // Fallback: without role
            if role != nil {
                fputs("[role] no \(role!) matching '\(label)[\(occurrence)]', trying without role\n", stderr)
                let fallback = TargetResolver.findAll(in: root, matching: label, scope: scopeElement, requiredRole: nil)
                if occurrence >= 1 && occurrence <= fallback.count {
                    return fallback[occurrence - 1].element
                }
            }
            // Fallback: without scope
            if scopeElement != nil {
                fputs("[within] '\(label)[\(occurrence)]' not found in '\(within!)', searching globally\n", stderr)
                let global = TargetResolver.findAll(in: root, matching: label, scope: nil, requiredRole: nil)
                if occurrence >= 1 && occurrence <= global.count {
                    return global[occurrence - 1].element
                }
            }
            throw BridgeError.elementNotFound(target)
        }

        // No occurrence specified — return first match
        if let first = matches.first {
            return first.element
        }

        // Fallback: without role
        if role != nil {
            fputs("[role] no \(role!) matching '\(label)', trying without role filter\n", stderr)
            let fallback = TargetResolver.findAll(in: root, matching: label, scope: scopeElement, requiredRole: nil)
            if let first = fallback.first { return first.element }
        }

        // Fallback: without scope
        if scopeElement != nil {
            fputs("[within] '\(label)' not found in '\(within!)', searching globally\n", stderr)
            let global = TargetResolver.findAll(in: root, matching: label, scope: nil, requiredRole: nil)
            if let first = global.first { return first.element }
        }

        throw BridgeError.elementNotFound(target)
    }

    /// Get parent of an AX element.
    public func getParent(of element: AXUIElement) -> AXUIElement? {
        getAttribute(element, kAXParentAttribute) as! AXUIElement?
    }

    /// Get role of an AX element.
    public func getRole(of element: AXUIElement) -> String? {
        getAttribute(element, kAXRoleAttribute) as? String
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
        // Direct lookup table for unshifted chars (lowercase letters, digits, common punctuation)
        let unshifted: [String: CGKeyCode] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, " ": 49, "`": 50,
        ]
        // Shifted symbols map to the keyCode of their base char (caller must apply shift).
        let shiftedSymbols: [Character: CGKeyCode] = [
            "!": 18, "@": 19, "#": 20, "$": 21, "%": 23, "^": 22,
            "&": 26, "*": 28, "(": 25, ")": 29, "_": 27, "+": 24,
            "{": 33, "}": 30, "|": 42, ":": 41, "\"": 39,
            "<": 43, ">": 47, "?": 44, "~": 50,
        ]
        if char == "\n" || char == "\r" { return 36 }
        if char == "\t" { return 48 }
        if let kc = shiftedSymbols[char] { return kc }
        // Uppercase letters and lowercase chars share the same keyCode (lowercased lookup).
        return unshifted[char.lowercased()]
    }

    // MARK: - Build

    /// Builds an Xcode project with camera mock injected via VFS overlay.
    public func buildWithCameraMock(args: [String]) throws {
        let interceptor = BuildInterceptor()
        try interceptor.build(args: args)
    }

    // MARK: - Inject (dylib)

    /// Well-known path where the mock reads images from.
    public static let injectImagePath = "/tmp/autopilot-camera-image.jpg"

    /// Copies an image to the well-known path so the mock picks it up on next capture.
    public func setInjectImage(_ sourcePath: String) throws {
        let absPath = sourcePath.hasPrefix("/") ? sourcePath : FileManager.default.currentDirectoryPath + "/" + sourcePath
        guard FileManager.default.fileExists(atPath: absPath) else {
            throw InjectError.imageNotFound(absPath)
        }
        let dest = SimulatorBridge.injectImagePath
        try? FileManager.default.removeItem(atPath: dest)
        try FileManager.default.copyItem(atPath: absPath, toPath: dest)
    }

    /// Launches an app with the camera mock dylib injected via DYLD_INSERT_LIBRARIES.
    /// Optionally sets an initial image for the mock.
    public func injectAndLaunch(bundleId: String, imagePath: String?, extraEnv: [String: String] = [:]) throws {
        let injector = DylibInjector()
        let dylibPath = try injector.ensureDylib()

        // Copy initial image if provided
        if let img = imagePath {
            try setInjectImage(img)
        }

        let deviceId = try getBootedDeviceId()

        // Terminate if running (ignore errors — app may not be running)
        let term = Process()
        term.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        term.arguments = ["simctl", "terminate", deviceId, bundleId]
        try? term.run()
        term.waitUntilExit()

        // Build env vars — only need dylib path, image is read from fixed file
        var env = ProcessInfo.processInfo.environment
        env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylibPath

        for (key, value) in extraEnv {
            env["SIMCTL_CHILD_\(key)"] = value
        }

        // Launch with dylib injection
        let launch = Process()
        launch.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        launch.arguments = ["simctl", "launch", deviceId, bundleId]
        launch.environment = env
        try launch.run()
        launch.waitUntilExit()

        guard launch.terminationStatus == 0 else {
            throw BridgeError.simctlFailed("simctl launch failed (exit \(launch.terminationStatus))")
        }
    }
}

// MARK: - DeviceBridge conformance

extension SimulatorBridge: DeviceBridge {
    /// Protocol-conforming wrapper (no AXUIElement parameter exposed).
    public func tree() throws -> [[String: Any]] {
        return try tree(element: nil)
    }

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

    // MARK: - Key Press

    public func pressKey(key: String) throws {
        let deviceId = try getBootedDeviceId()

        switch key.lowercased() {
        case "home":
            // Use AppleScript — simctl sendButtonPress removed in Xcode 26
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

    // MARK: - Hide Keyboard

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

    // MARK: - Erase Text

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

    // MARK: - Copy Text From Element

    public func copyTextFrom(target: String) throws -> String {
        let root = try findSimulatorContent()
        guard let axElement = findAXElement(in: root, matching: target, depth: 0, maxDepth: 20) else {
            throw BridgeError.elementNotFound(target)
        }

        // Try kAXValueAttribute first
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXValueAttribute as CFString, &value)
        if let str = value as? String, !str.isEmpty {
            return str
        }

        // Fallback to kAXTitleAttribute
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(axElement, kAXTitleAttribute as CFString, &title)
        if let str = title as? String, !str.isEmpty {
            return str
        }

        throw BridgeError.unknown("No text value found for element '\(target)'")
    }

    // MARK: - Clear State

    public func clearState(bundleId: String) throws {
        let deviceId = try getBootedDeviceId()

        // Reset privacy permissions
        let resetProcess = Process()
        resetProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        resetProcess.arguments = ["simctl", "privacy", deviceId, "reset", "all", bundleId]
        try resetProcess.run()
        resetProcess.waitUntilExit()

        // Get app data container and delete its contents
        let containerProcess = Process()
        let pipe = Pipe()
        containerProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        containerProcess.arguments = ["simctl", "get_app_container", deviceId, bundleId, "data"]
        containerProcess.standardOutput = pipe
        containerProcess.standardError = Pipe()
        try containerProcess.run()
        containerProcess.waitUntilExit()

        if containerProcess.terminationStatus == 0 {
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let containerPath = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !containerPath.isEmpty {
                let fm = FileManager.default
                if let contents = try? fm.contentsOfDirectory(atPath: containerPath) {
                    for item in contents {
                        try? fm.removeItem(atPath: containerPath + "/" + item)
                    }
                }
            }
        }
    }

    // MARK: - Uninstall App

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

    // MARK: - Secure Storage

    /// Reset the booted simulator's shared keychain. Wraps
    /// `xcrun simctl keychain <udid> reset` — clears credentials saved
    /// by Keychain Services across ALL apps on the device. There is no
    /// per-bundle reset at the simctl level.
    ///
    /// This is the critical piece of the "fresh install" flow for login
    /// automation: iOS keeps keychain entries across `uninstall` +
    /// `install` of a bundle, so re-running a login script on a simulator
    /// that already logged in once will skip past the login screen
    /// because the app reads the saved credentials. Calling this before
    /// `install` guarantees a true first-run state.
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

    // MARK: - Screen Recording

    public func startRecording() throws {
        let deviceId = try getBootedDeviceId()
        let tempPath = NSTemporaryDirectory() + "autopilot-recording-\(ProcessInfo.processInfo.globallyUniqueString).mp4"
        recordingTempPath = tempPath

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", deviceId, "recordVideo", "--codec=h264", tempPath]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        recordingProcess = process
    }

    public func stopRecording(outputPath: String) throws {
        guard let process = recordingProcess else {
            throw BridgeError.unknown("No recording in progress")
        }

        // Send SIGINT to stop recording gracefully
        process.interrupt()
        process.waitUntilExit()

        guard let tempPath = recordingTempPath else {
            throw BridgeError.unknown("No recording temp path found")
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: outputPath) {
            try fm.removeItem(atPath: outputPath)
        }
        try fm.moveItem(atPath: tempPath, toPath: outputPath)

        recordingProcess = nil
        recordingTempPath = nil
    }

    // MARK: - Location

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

    // MARK: - Appearance

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

    // MARK: - Lock / Unlock

    public func lockDevice() throws {
        // Use AppleScript — simctl sendButtonPress removed in Xcode 26
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Lock" of menu "Device" of menu bar 1
        """)
    }

    public func unlockDevice() throws {
        try clickSimulatorMenu("""
        tell application "System Events" to tell process "Simulator" to click menu item "Home" of menu "Device" of menu bar 1
        """)
    }

    // MARK: - Push / Pull File

    public func pushFile(localPath: String, remotePath: String) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: localPath) else {
            throw BridgeError.unknown("Local file not found: '\(localPath)'")
        }

        var destPath = remotePath
        if !remotePath.hasPrefix("/") {
            let deviceId = try getBootedDeviceId()
            let containerProcess = Process()
            let pipe = Pipe()
            containerProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            containerProcess.arguments = ["simctl", "get_app_container", deviceId,
                                          remotePath.components(separatedBy: "/").first ?? "", "data"]
            containerProcess.standardOutput = pipe
            containerProcess.standardError = Pipe()
            try containerProcess.run()
            containerProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let container = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if container.isEmpty {
                throw BridgeError.simctlFailed("Could not resolve app container for remotePath")
            }
            destPath = container + "/" + remotePath
        }

        if fm.fileExists(atPath: destPath) {
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
            let deviceId = try getBootedDeviceId()
            let containerProcess = Process()
            let pipe = Pipe()
            containerProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
            containerProcess.arguments = ["simctl", "get_app_container", deviceId,
                                          remotePath.components(separatedBy: "/").first ?? "", "data"]
            containerProcess.standardOutput = pipe
            containerProcess.standardError = Pipe()
            try containerProcess.run()
            containerProcess.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let container = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if container.isEmpty {
                throw BridgeError.simctlFailed("Could not resolve app container for remotePath")
            }
            srcPath = container + "/" + remotePath
        }

        guard fm.fileExists(atPath: srcPath) else {
            throw BridgeError.unknown("Remote file not found: '\(srcPath)'")
        }

        if fm.fileExists(atPath: localPath) {
            try fm.removeItem(atPath: localPath)
        }

        // Ensure parent directory exists
        let parentDir = (localPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        try fm.copyItem(atPath: srcPath, toPath: localPath)
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
}
