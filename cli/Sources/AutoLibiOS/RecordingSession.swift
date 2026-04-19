import Foundation
import ApplicationServices
import AutoCore

/// Orchestrates the semantic recorder: event capture → resolution → script generation.
public final class RecordingSession {

    private let bridge: SimulatorBridge
    private let stabilizer = UIStabilizer()
    private var recorder: EventRecorder?
    private let generator = ScriptGenerator()
    private let outputPath: String
    private let resolveQueue = DispatchQueue(label: "autopilot.resolve", qos: .userInitiated)

    // Phase 4a: Keyboard buffer
    private var keystrokeBuffer = ""
    private var keystrokeFlushWork: DispatchWorkItem?
    private var lastFocusedElement: AXUIElement?

    // Phase 4d: Long press / double tap detection
    private var pendingMouseDown: (event: RawEvent, root: AXUIElement)?
    private var pendingTap: (action: ResolvedAction, timestamp: CFAbsoluteTime)?
    private var pendingTapWork: DispatchWorkItem?

    // Cached state
    private var simulatorPID: pid_t = 0

    // #52: stale AX tree detection en clicks consecutivos rápidos.
    // Si el anterior mouseDown sucedió hace < `fastClickWindow` y el tree
    // sigue matcheando el fingerprint de entonces, esperamos a que el
    // tree cambie o a que pase `staleTreeTimeout` antes de capturarlo.
    // Esto evita que resolvamos el segundo click contra el estado pre-primer-click.
    private var lastMouseDownTimestamp: CFAbsoluteTime = 0
    private var lastCapturedFingerprint: ViewFingerprint?
    private let fastClickWindow: CFAbsoluteTime = 0.25     // 250ms
    private let staleTreeTimeout: CFAbsoluteTime = 0.30    // 300ms max wait
    private let pollInterval: useconds_t = 15_000           // 15ms

    public init(bridge: SimulatorBridge, outputPath: String) {
        self.bridge = bridge
        self.outputPath = outputPath
    }

    // MARK: - Start / Stop

    public func start() throws {
        // 1. Find Simulator
        guard let pid = bridge.findSimulatorPID() else {
            throw BridgeError.simulatorNotRunning
        }
        simulatorPID = pid

        // 2. Verify AX access
        let _ = try bridge.findSimulatorContent()

        // 3. Phase 4c: terminate + launch if bundle configured
        if let bundleId = AutoPilotConfig.get("bundle") {
            generator.appendRaw("terminate \"\(bundleId)\"")
            generator.appendRaw("launch \"\(bundleId)\"")
            generator.appendRaw("")
        }

        // 4. Attach stabilizer for UI change tracking
        stabilizer.attach(pid: pid)

        // 5. Start event recorder with Simulator window bounds
        let eventRecorder = EventRecorder(simulatorPID: pid)
        eventRecorder.windowFrame = bridge.getSimulatorWindowFrame() ?? .zero
        self.recorder = eventRecorder

        print("Recording... Interact with the Simulator. Press Ctrl+C to stop.\n")

        eventRecorder.start { [weak self] event in
            self?.handleEvent(event)
        }
    }

    public func stop() throws -> String {
        // Stop capturing
        recorder?.stop()
        stabilizer.detach()

        // Flush pending work synchronously on resolveQueue
        resolveQueue.sync {
            flushKeystrokeBuffer()
            flushPendingTap()
            flushScroll()
        }

        // Write script
        let script = generator.render()
        try script.write(toFile: outputPath, atomically: true, encoding: .utf8)

        let count = generator.lineCount
        print("\n\(count) line(s) recorded → \(outputPath)")

        return outputPath
    }

    // MARK: - Event Handling

    /// Called on EventRecorder's thread — capture AX tree HERE before dispatching.
    private func handleEvent(_ event: RawEvent) {
        switch event.kind {
        case .mouseDown:
            // Capture AX tree NOW on the event tap thread, BEFORE the click processes.
            // #52: si hubo un mouseDown muy reciente, el tree del Simulator puede
            // no haber aplicado los cambios del click anterior. Esperamos a que
            // el fingerprint cambie (UI reaccionó) o timeout.
            let root = captureRootAvoidingStaleTree(for: event)
            resolveQueue.async { [weak self] in
                self?.handleMouseDown(event, root: root)
            }

        case .mouseUp:
            resolveQueue.async { [weak self] in
                self?.handleMouseUp(event)
            }

        case .keyDown(let keyCode):
            resolveQueue.async { [weak self] in
                self?.handleKeyDown(keyCode, event: event)
            }

        case .scrollWheel(let deltaY):
            resolveQueue.async { [weak self] in
                self?.handleScroll(deltaY: deltaY, event: event)
            }
        }
    }

    // MARK: - Stale tree guard (#52)

    /// Captura el root AX evitando tree stale tras clicks consecutivos rápidos.
    ///
    /// **El problema** (#52): tras un click, Simulator tarda un frame en
    /// propagar el cambio visual al AX subsystem de macOS. Si el usuario
    /// hace otro click <250ms después, `findSimulatorContentFast()` devuelve
    /// el tree de ANTES del primer click, y el recorder resuelve el segundo
    /// click contra ese estado viejo — emitiendo `tap` con el selector
    /// equivocado.
    ///
    /// **Fix**: si pasaron menos de `fastClickWindow` ms desde el último
    /// mouseDown, verificamos si el tree cambió respecto al fingerprint
    /// capturado entonces. Si no cambió, poll cada 15ms hasta que cambie
    /// o hasta `staleTreeTimeout`. Timeout no es error — usamos el tree
    /// actual aunque parezca stale (es la mejor info disponible).
    private func captureRootAvoidingStaleTree(for event: RawEvent) -> AXUIElement? {
        let now = event.timestamp
        let elapsed = now - lastMouseDownTimestamp

        guard elapsed < fastClickWindow, let priorFp = lastCapturedFingerprint else {
            // No-fast-click o primer click — captura directa
            let root = bridge.findSimulatorContentFast()
            lastMouseDownTimestamp = now
            lastCapturedFingerprint = root.flatMap { ViewFingerprint.capture(root: $0) }
            return root
        }

        // Fast consecutive click — poll hasta que el fingerprint cambie
        let deadline = now + staleTreeTimeout
        var root = bridge.findSimulatorContentFast()
        var current = root.flatMap { ViewFingerprint.capture(root: $0) }
        while current == priorFp && CFAbsoluteTimeGetCurrent() < deadline {
            usleep(pollInterval)
            root = bridge.findSimulatorContentFast()
            current = root.flatMap { ViewFingerprint.capture(root: $0) }
        }

        lastMouseDownTimestamp = CFAbsoluteTimeGetCurrent()
        lastCapturedFingerprint = current
        return root
    }

    // MARK: - Mouse Events (Phase 3 + Phase 4d edge cases)

    private func handleMouseDown(_ event: RawEvent, root: AXUIElement?) {
        // Flush any pending keystroke buffer on click
        flushKeystrokeBuffer()

        guard let root else { return }

        // Store for potential long press detection via mouseUp
        pendingMouseDown = (event: event, root: root)

        let action = SemanticResolver.resolveClick(
            at: event.location, root: root, command: "tap"
        )
        // Phase 4d: Double tap detection
        if let pending = pendingTap,
           event.timestamp - pending.timestamp < 0.3,
           pending.action.selector == action.selector {
            // Cancel the pending single tap
            pendingTapWork?.cancel()
            pendingTap = nil
            pendingTapWork = nil

            // Emit double tap
            let doubleTapAction = ResolvedAction(
                command: "doubleTap",
                selector: action.selector,
                role: action.role, within: action.within,
                occurrence: action.occurrence,
                identifier: action.identifier,
                fragile: action.fragile,
                coordinate: action.coordinate
            )
            emitAction(doubleTapAction)
            return
        }

        // Buffer this tap for 300ms to check for double tap
        pendingTap = (action: action, timestamp: event.timestamp)
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingTap()
        }
        pendingTapWork = work
        resolveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func handleMouseUp(_ event: RawEvent) {
        guard let mouseDown = pendingMouseDown else { return }
        pendingMouseDown = nil

        let duration = event.timestamp - mouseDown.event.timestamp

        // Phase 4d: Long press detection (> 0.5s hold)
        if duration > 0.5 {
            // Cancel the pending tap and re-emit as longPress
            pendingTapWork?.cancel()
            pendingTap = nil
            pendingTapWork = nil

            let action = SemanticResolver.resolveClick(
                at: mouseDown.event.location, root: mouseDown.root, command: "longPress"
            )
            emitAction(action)
        }
    }

    private func flushPendingTap() {
        guard let pending = pendingTap else { return }
        pendingTapWork?.cancel()
        pendingTap = nil
        pendingTapWork = nil
        emitAction(pending.action)
    }

    // MARK: - Keyboard Events (Phase 4a)

    private func handleKeyDown(_ keyCode: UInt16, event: RawEvent) {
        // Skip modifier-only keys
        let modifierKeys: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        if modifierKeys.contains(keyCode) { return }

        // Check for special keys
        if let specialCommand = specialKeyCommand(keyCode, flags: event.flags) {
            flushKeystrokeBuffer()
            let line = specialCommand
            generator.appendRaw(line)
            printRecorded(line)
            return
        }

        // Convert keycode to character
        guard let char = keyCodeToCharacter(keyCode, flags: event.flags) else { return }

        keystrokeBuffer.append(char)

        // Reschedule flush debounce (300ms)
        keystrokeFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushKeystrokeBuffer()
        }
        keystrokeFlushWork = work
        resolveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func flushKeystrokeBuffer() {
        keystrokeFlushWork?.cancel()
        keystrokeFlushWork = nil

        guard !keystrokeBuffer.isEmpty else { return }
        let text = keystrokeBuffer
        keystrokeBuffer = ""

        let action = ResolvedAction(
            command: "type",
            selector: text,
            role: nil, within: nil, occurrence: nil,
            identifier: nil, fragile: false, coordinate: .zero
        )
        emitAction(action)
    }

    /// Map special key codes to .auto commands.
    private func specialKeyCommand(_ keyCode: UInt16, flags: CGEventFlags) -> String? {
        switch keyCode {
        case 36:  return "pressKey \"enter\""     // Return
        case 51:  return "pressKey \"delete\""    // Backspace
        case 53:  return "pressKey \"escape\""    // Escape
        case 48:  return "pressKey \"tab\""       // Tab
        case 115: return "pressKey \"home\""      // Home
        default:  return nil
        }
    }

    /// Convert a virtual key code to a character string.
    private func keyCodeToCharacter(_ keyCode: UInt16, flags: CGEventFlags) -> Character? {
        // Use CGEvent to get the unicode string
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true) else {
            return nil
        }
        // Apply shift if held
        if flags.contains(.maskShift) {
            event.flags = .maskShift
        }

        var length: Int = 0
        var chars = [UniChar](repeating: 0, count: 4)
        event.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &chars)

        guard length > 0 else { return nil }
        return Character(UnicodeScalar(chars[0])!)
    }

    // MARK: - Scroll Events (Phase 4d)

    private var scrollAccumulator: Double = 0
    private var scrollFlushWork: DispatchWorkItem?
    private var lastScrollLocation: CGPoint = .zero

    private func handleScroll(deltaY: Double, event: RawEvent) {
        scrollAccumulator += deltaY
        lastScrollLocation = event.location

        // Debounce: flush after 200ms of scroll silence
        scrollFlushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushScroll()
        }
        scrollFlushWork = work
        resolveQueue.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func flushScroll() {
        scrollFlushWork?.cancel()
        scrollFlushWork = nil

        let delta = scrollAccumulator
        scrollAccumulator = 0

        guard abs(delta) > 0.5 else { return } // Ignore tiny scrolls

        let direction = delta > 0 ? "up" : "down"

        // Try to resolve element under scroll position
        if let root = bridge.findSimulatorContentFast() {
            let element = hitTestForScroll(at: lastScrollLocation, root: root)
            if let selector = element {
                let line = "scroll \"\(selector)\" \(direction)"
                generator.appendRaw(line)
                printRecorded(line)
                appendPostScrollWait()
                return
            }
        }

        // Fallback: generic swipe
        let line = "swipe \(direction)"
        generator.appendRaw(line)
        printRecorded(line)
        appendPostScrollWait()
    }

    /// Auto-inject wait after scroll/swipe so the AX tree settles before next tap (#63)
    private func appendPostScrollWait() {
        let waitLine = "wait 0.5"
        generator.appendRaw(waitLine)
        printRecorded(waitLine)
    }

    /// Find a scrollable element near the given point for scroll commands.
    private func hitTestForScroll(at point: CGPoint, root: AXUIElement) -> String? {
        var element: AXUIElement?
        let result = AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element)
        guard result == .success, let element else { return nil }

        // Walk up to find a scrollable container or named element
        var current = element
        for _ in 0..<5 {
            let role = AXDebug.axGetRole(of: current)

            // If this is a scrollable area, use its label
            if role == "AXScrollArea" || role == "AXTable" || role == "AXList" {
                return axLabel(of: current)
            }

            // If this has a good label, use it
            if let label = axLabel(of: current), !label.isEmpty {
                return label
            }

            guard let parent = AXDebug.axGetParent(of: current) else { break }
            current = parent
        }

        return nil
    }

    private func axLabel(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &ref)
        if let s = ref as? String, !s.isEmpty { return s }
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &ref)
        if let s = ref as? String, !s.isEmpty { return s }
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &ref)
        if let s = ref as? String, !s.isEmpty { return s }
        return nil
    }

    // MARK: - Phase 4d: System Dialog Detection

    /// Check if an element is inside a system permission dialog.
    /// Returns a permission grant command if so, nil otherwise.
    private func detectSystemDialog(_ element: AXUIElement, selector: String) -> String? {
        var current = element
        for _ in 0..<8 {
            let role = AXDebug.axGetRole(of: current)
            if role == "AXSheet" || role == "AXDialog" {
                // Check if the selector looks like a permission button
                let lower = selector.lowercased()
                let allowWords = ["allow", "ok", "permitir", "aceptar"]
                let denyWords = ["don't allow", "no permitir", "deny", "cancel", "cancelar"]

                if denyWords.contains(where: { lower.contains($0) }) {
                    return nil // Don't auto-handle deny
                }
                if allowWords.contains(where: { lower.contains($0) }) {
                    // Try to determine which permission
                    if let dialogTitle = dialogTitleText(from: current) {
                        let service = guessPermissionService(dialogTitle)
                        if let bundleId = AutoPilotConfig.get("bundle") {
                            return "permission grant \(service) \(bundleId)"
                        }
                    }
                }
                break
            }
            guard let parent = AXDebug.axGetParent(of: current) else { break }
            current = parent
        }
        return nil
    }

    /// Extract dialog title text.
    private func dialogTitleText(from dialog: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(dialog, kAXTitleAttribute as CFString, &ref)
        if let s = ref as? String, !s.isEmpty { return s }

        // Try first static text child
        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(dialog, kAXChildrenAttribute as CFString, &childrenRef)
        if let children = childrenRef as? [AXUIElement] {
            for child in children {
                let role = AXDebug.axGetRole(of: child)
                if role == "AXStaticText" {
                    var textRef: CFTypeRef?
                    AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &textRef)
                    if let s = textRef as? String, !s.isEmpty { return s }
                }
            }
        }
        return nil
    }

    /// Guess the permission service from dialog text.
    private func guessPermissionService(_ text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("camera") || lower.contains("camara") { return "camera" }
        if lower.contains("microphone") || lower.contains("microfono") { return "microphone" }
        if lower.contains("photo") || lower.contains("foto") { return "photos" }
        if lower.contains("location") || lower.contains("ubicacion") { return "location" }
        if lower.contains("notification") || lower.contains("notificacion") { return "notifications" }
        if lower.contains("contact") || lower.contains("contacto") { return "contacts" }
        if lower.contains("calendar") || lower.contains("calendario") { return "calendars" }
        return "all"
    }

    // MARK: - Emit

    private func emitAction(_ action: ResolvedAction) {
        // Phase 4d: Check for system dialog
        if action.command == "tap" {
            if let root = bridge.findSimulatorContentFast(),
               let element = hitTestElement(at: action.coordinate, root: root),
               let permissionCmd = detectSystemDialog(element, selector: action.selector) {
                generator.appendRaw(permissionCmd)
                printRecorded(permissionCmd)
                return
            }
        }

        // Auto-inject scrollUntilVisible if the tapped element exists in the tree
        // but is offscreen. The user scrolled to it with a trackpad gesture that
        // CGEventTap can't capture (those go straight to the Simulator), so
        // without this the replay fails: the AX tree includes offscreen elements
        // so the tap "finds" a target, but the coordinates don't hit anything.
        if action.command == "tap" && !action.selector.isEmpty {
            injectScrollIfOffscreen(for: action)
        }

        // Phase 4b: waitFor injection based on time gap between actions
        let outputLines = generator.process(action, uiChanges: 0)

        for line in outputLines {
            printRecorded(line)
        }
    }

    /// If the target selector resolves to an element whose frame is outside
    /// the viewport, emit a `scrollUntilVisible` line before the tap.
    private func injectScrollIfOffscreen(for action: ResolvedAction) {
        guard let tree = try? bridge.tree(),
              let screen = bridge.getSimulatorWindowFrame(),
              let line = RecorderScrollHelper.scrollLine(forSelector: action.selector,
                                                         in: tree,
                                                         viewport: screen) else {
            return
        }
        generator.appendRaw(line)
        printRecorded(line)
    }


    private func hitTestElement(at point: CGPoint, root: AXUIElement) -> AXUIElement? {
        guard point != .zero else { return nil }
        var element: AXUIElement?
        AXUIElementCopyElementAtPosition(root, Float(point.x), Float(point.y), &element)
        return element
    }

    private func printRecorded(_ line: String) {
        if line.hasPrefix("#") {
            print("       \(line)")
        } else {
            print("[REC]  \(line)")
        }
    }
}
