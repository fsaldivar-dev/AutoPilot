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

    // Phase 4d: Double tap detection
    private var pendingTap: (action: ResolvedAction, timestamp: CFAbsoluteTime)?
    private var pendingTapWork: DispatchWorkItem?

    // #91: gesto activo down→dragged*→up. Acumula la trayectoria completa
    // para que GestureClassifier decida tap/longPress/swipe/drag al soltar.
    private struct ActiveGesture {
        let downEvent: RawEvent
        let root: AXUIElement?     // tree PRE-click (intento 3 del capítulo 13)
        var points: [GesturePoint]
    }
    private var activeGesture: ActiveGesture?

    // Cached state
    private var simulatorPID: pid_t = 0

    // #132: refresco periódico del window frame. El frame se capturaba una
    // sola vez en start() — si el usuario movía/redimensionaba la ventana del
    // Simulator a mitad de la grabación, todos los clicks posteriores caían
    // fuera del frame stale y se filtraban en silencio.
    private var windowFrameTimer: DispatchSourceTimer?

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
        let frame = bridge.getSimulatorWindowFrame()
        eventRecorder.windowFrame = frame ?? .zero
        if frame == nil {
            // #132: sin frame, EventRecorder captura TODO el escritorio
            // (fail-open) en vez de descartar clicks en silencio. Avisar.
            fputs("[record] WARNING: no pude determinar el frame de la ventana del Simulator — se grabarán clicks de todo el escritorio.\n", stderr)
        }
        self.recorder = eventRecorder

        // #132: refrescar el frame cada 1s por si el usuario mueve/redimensiona
        // la ventana del Simulator durante la grabación.
        startWindowFrameRefresh()

        print("Recording... Interact with the Simulator. Press Ctrl+C to stop.\n")
        // #132: el recorder captura CGEvents de hardware (mouse/teclado del
        // host). Los taps sintéticos del propio CLI (`auto tap`) usan AXPress
        // o XCUITest dentro del simulador — no generan CGEvents y el recorder
        // no puede verlos. Es una limitación arquitectónica, no un bug.
        print("Nota: los taps del propio CLI (`auto tap`) no se graban — usa clicks reales sobre la ventana del Simulator.\n")

        eventRecorder.start { [weak self] event in
            self?.handleEvent(event)
        }
    }

    private func startWindowFrameRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: resolveQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self, let recorder = self.recorder else { return }
            // Si el lookup falla momentáneamente, conservamos el último frame
            // conocido — nunca degradamos a .zero desde un frame válido.
            if let frame = self.bridge.getSimulatorWindowFrame() {
                recorder.windowFrame = frame
            }
        }
        timer.resume()
        windowFrameTimer = timer
    }

    public func stop() throws -> String {
        // Stop capturing
        recorder?.stop()
        stabilizer.detach()
        windowFrameTimer?.cancel()
        windowFrameTimer = nil

        // Flush pending work synchronously on resolveQueue
        resolveQueue.sync {
            flushKeystrokeBuffer()
            flushPendingTap()
            flushScroll()
        }

        // Write script
        let script = generator.render()
        try script.write(toFile: outputPath, atomically: true, encoding: .utf8)

        // #133 (aplica igual en iOS): reportar comandos ejecutables — lineCount
        // incluye la línea en blanco del header terminate/launch y comments.
        let count = generator.commandCount
        print("\n\(count) command(s) recorded → \(outputPath)")

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

        case .mouseDragged:
            resolveQueue.async { [weak self] in
                self?.handleMouseDragged(event)
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

    // MARK: - Mouse Events (Phase 3 + Phase 4d edge cases + #91 gestures)

    /// #91: el mouseDown ya no emite nada — solo abre el gesto y guarda el
    /// tree PRE-click. La decisión (tap/longPress/swipe/drag) se toma en el
    /// mouseUp con la trayectoria completa. Antes, un drag del usuario se
    /// grababa como `tap` en el punto de origen porque la resolución ocurría
    /// aquí, ciega a los mouseDragged.
    private func handleMouseDown(_ event: RawEvent, root: AXUIElement?) {
        // Flush any pending keystroke buffer on click
        flushKeystrokeBuffer()

        // root nil ya no descarta el gesto (#132 fail-open): swipes no
        // necesitan tree y tap/drag caen a coordenadas.
        activeGesture = ActiveGesture(
            downEvent: event,
            root: root,
            points: [GesturePoint(location: event.location, timestamp: event.timestamp)]
        )
    }

    private func handleMouseDragged(_ event: RawEvent) {
        // Sin gesto activo (click iniciado fuera de la ventana o antes de
        // arrancar la grabación) los dragged se ignoran.
        activeGesture?.points.append(
            GesturePoint(location: event.location, timestamp: event.timestamp)
        )
    }

    private func handleMouseUp(_ event: RawEvent) {
        guard var gesture = activeGesture else { return }
        activeGesture = nil
        gesture.points.append(
            GesturePoint(location: event.location, timestamp: event.timestamp)
        )

        guard let classified = GestureClassifier.classify(points: gesture.points) else { return }

        // Un gesto no-tap cierra la ventana de double-tap: flush del tap
        // pendiente ANTES de emitir la línea nueva para preservar el orden
        // en el script (el tap ocurrió primero).
        if case .tap = classified {} else {
            flushPendingTap()
        }

        switch classified {
        case .tap:
            emitTap(gesture)
        case .longPress(let duration):
            emitLongPress(gesture, duration: duration)
        case .swipe(let direction):
            emitSwipe(direction, gesture: gesture)
        case .drag(let from, let to):
            emitDrag(from: from, to: to, root: gesture.root)
        }
    }

    // MARK: - #91: Emission per gesture kind

    /// Resuelve un punto contra el tree; sin tree cae a `tapAt x y` (fragil
    /// pero presente — mismo criterio que el fix #133 en Android).
    private func resolveOrFallback(at point: CGPoint, root: AXUIElement?, command: String) -> ResolvedAction {
        if let root {
            return SemanticResolver.resolveClick(at: point, root: root, command: command)
        }
        return ResolvedAction(
            command: "tapAt",
            selector: "\(Int(point.x)) \(Int(point.y))",
            role: nil, within: nil, occurrence: nil,
            identifier: nil, fragile: true, coordinate: point
        )
    }

    private func emitTap(_ gesture: ActiveGesture) {
        let action = resolveOrFallback(
            at: gesture.downEvent.location, root: gesture.root, command: "tap"
        )

        // Phase 4d: Double tap detection (comparado por timestamp del down)
        if let pending = pendingTap,
           gesture.downEvent.timestamp - pending.timestamp < 0.3,
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
        pendingTap = (action: action, timestamp: gesture.downEvent.timestamp)
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingTap()
        }
        pendingTapWork = work
        resolveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func emitLongPress(_ gesture: ActiveGesture, duration: CFAbsoluteTime) {
        let resolved = resolveOrFallback(
            at: gesture.downEvent.location, root: gesture.root, command: "longPress"
        )
        // El dispatcher usa 1.0s por default — solo emitimos la duración
        // explícita cuando el hold real fue mayor (`longPress "X" 1.5`).
        let secs = (duration * 10).rounded() / 10
        let suffix = (resolved.command == "longPress" && secs > 1.0 && resolved.within == nil)
            ? String(format: "%.1f", secs) : nil
        let action = ResolvedAction(
            command: resolved.command,
            selector: resolved.selector,
            role: resolved.role, within: resolved.within,
            occurrence: resolved.occurrence,
            identifier: resolved.identifier,
            fragile: resolved.fragile,
            coordinate: resolved.coordinate,
            argsSuffix: suffix
        )
        emitAction(action)
    }

    /// Swipe rápido y axial: si el punto de origen resuelve a un contenedor
    /// scrolleable/etiquetado emitimos `scroll "<elem>" <dir>`, si no
    /// `swipe <dir>` genérico. Igual que el flush del scrollWheel (#50).
    private func emitSwipe(_ direction: SwipeDirection, gesture: ActiveGesture) {
        let line: String
        if let root = gesture.root,
           let selector = hitTestForScroll(at: gesture.downEvent.location, root: root) {
            line = "scroll \"\(selector)\" \(direction.rawValue)"
        } else {
            line = "swipe \(direction.rawValue)"
        }
        generator.appendRaw(line)
        printRecorded(line)
        appendPostScrollWait()
    }

    /// Drag deliberado: resolver AMBOS extremos por hit-test contra el tree
    /// PRE-gesto (el elemento origen todavía está en su lugar y el destino
    /// es lo que había bajo el punto de drop). Si alguno no resuelve
    /// semánticamente, ambos extremos caen a coordenadas — el comando `drag`
    /// exige los dos extremos del mismo tipo (`drag "A" "B"` o
    /// `drag x1,y1 x2,y2`).
    private func emitDrag(from: CGPoint, to: CGPoint, root: AXUIElement?) {
        let fromAction = resolveOrFallback(at: from, root: root, command: "drag")
        let toAction = resolveOrFallback(at: to, root: root, command: "drag")

        let line: String
        if fromAction.command == "drag" && toAction.command == "drag"
            && fromAction.selector != toAction.selector {
            line = "drag \"\(fromAction.selector)\" \"\(toAction.selector)\""
            if fromAction.fragile || toAction.fragile {
                let warning = "# no accessibilityIdentifier — selector may be fragile"
                generator.appendRaw(warning)
                printRecorded(warning)
            }
        } else {
            // Extremos sin selector estable (o ambos resuelven al mismo
            // elemento, p.ej. un slider que viaja con el puntero) →
            // coordenadas crudas.
            let warning = "# drag por coordenadas — puede romper si cambia el layout"
            generator.appendRaw(warning)
            printRecorded(warning)
            line = "drag \(Int(from.x)),\(Int(from.y)) \(Int(to.x)),\(Int(to.y))"
        }
        generator.appendRaw(line)
        printRecorded(line)
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
