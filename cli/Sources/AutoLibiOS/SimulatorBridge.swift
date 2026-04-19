import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import AutoCore

/// Controls the iOS Simulator directly via macOS Accessibility APIs.
/// No XCUITest, no xcodebuild, no test runner needed.
public final class SimulatorBridge {

    // Internal visibility — accedidos desde extensions en archivos separados
    // (SimulatorBridge+MediaEngine.swift, etc.)
    var simulatorPID: pid_t?
    var recordingProcess: Process?
    var recordingTempPath: String?

    public init() {}

    // findSimulator / tree / search / elementAt → SimulatorBridge+AXEngine.swift

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
    // screenshot() → SimulatorBridge+MediaEngine.swift

    // Todos los métodos simctl (launch/terminate/install/etc., biometry, pasteboard,
    // listDevices/boot/shutdown, openURL) → SimulatorBridge+SimCtlEngine.swift

    // Simulator access + AX helpers (findSimulatorPID, findSimulatorContent,
    // getSimulatorWindowFrame, findSimulatorContentFast, getFirstWindow,
    // getPosition, getSize) → SimulatorBridge+AXEngine.swift

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

    // MARK: - Click primitive (internal — usado por tapElement en AXEngine ext)

    func click(at point: CGPoint) throws {
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

    // Todos los métodos AX (serialize*, searchRecursive, existsFast, findAXElement*,
    // findElementInfo, findElementAt, tapElement, findAXElementScoped, getParent,
    // getRole, getAttribute, getChildren) → SimulatorBridge+AXEngine.swift

    // getBootedDeviceId() → SimulatorBridge+SimCtlEngine.swift

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

    // Build + Inject (buildWithCameraMock / setInjectImage / injectAndLaunch)
    // → SimulatorBridge+MediaEngine.swift
}

// MARK: - DeviceBridge conformance

extension SimulatorBridge: DeviceBridge {
    /// Protocol-conforming wrapper (no AXUIElement parameter exposed).
    public func tree() throws -> [[String: Any]] {
        return try tree(element: nil)
    }

    // Copy text (AX read) queda acá por ser gesture-lindero — usa findAXElement
    // de AXEngine pero no es simctl.
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

    // Todos los métodos simctl de DeviceBridge (getLogs/setPermission/pressKey/
    // hideKeyboard/eraseText/clearState/uninstallApp/resetKeychain/viewport/
    // setLocation/setAppearance/lockDevice/unlockDevice/pushFile/pullFile/rotate)
    // → SimulatorBridge+SimCtlEngine.swift
}
