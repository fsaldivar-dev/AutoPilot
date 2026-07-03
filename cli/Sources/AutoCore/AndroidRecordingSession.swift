import Foundation

/// Orchestrates the Android semantic recorder: getevent capture → resolution → script generation.
/// Uses `adb shell getevent -lt` to passively capture touch events from the device kernel.
public final class AndroidRecordingSession {

    private let bridge: any DeviceBridge
    private let generator = ScriptGenerator()
    private let outputPath: String
    private let resolveQueue = DispatchQueue(label: "autopilot.android.resolve", qos: .userInitiated)

    // getevent process
    private var getEventProcess: Process?
    private var parser: GetEventParser?
    // #133: señalado por el reader thread al llegar a EOF, DESPUÉS de drenar
    // el buffer completo (incluida la línea parcial final). `stop()` espera
    // esta señal antes de flushear — sin ella, los últimos eventos del pipe
    // podían encolarse en resolveQueue después del flush y perderse.
    private let readerDrained = DispatchSemaphore(value: 0)

    // Gesture state machine
    private var touchDownPoint: (x: Int, y: Int)?
    private var touchDownTimestamp: Double = 0
    private var touchDownTree: [[String: Any]]?
    private var lastMovePoint: (x: Int, y: Int)?

    // Tree cache — refreshed in background to avoid 2s uiautomator dump at touch time
    private var cachedTree: [[String: Any]]?
    private var treeCacheTimer: DispatchSourceTimer?

    // Double tap detection
    private var pendingTap: (action: ResolvedAction, timestamp: Double)?
    private var pendingTapWork: DispatchWorkItem?

    // #54: sesión de tecleo sobre el teclado virtual (ventana IME del tree).
    // Mientras está activa, los toques dentro del IME se absorben y al cerrar
    // se emite UN `type "<texto>"` con el diff del value del campo enfocado.
    private var keyboardActive = false
    private var keyboardValueBefore: String?
    // Último value del campo enfocado visto por el refresh del tree cache
    // mientras la sesión de tecleo está activa — fallback si al finalizar
    // el campo ya perdió el foco.
    private var keyboardValueLatest: String?

    public init(bridge: any DeviceBridge, outputPath: String) {
        self.bridge = bridge
        self.outputPath = outputPath
    }

    // MARK: - Start / Stop

    public func start() throws {
        // 1. Verify device connection
        let devices = try bridge.listDevices()
        guard !devices.isEmpty else {
            throw BridgeError.noBootedDevice
        }

        // 2. Get touch calibration
        let calibration = try getTouchCalibration()
        parser = GetEventParser(calibration: calibration)

        // 3. Auto-inject terminate + launch for the current foreground app
        if let bundleId = detectForegroundApp() {
            generator.appendRaw("terminate \"\(bundleId)\"")
            generator.appendRaw("launch \"\(bundleId)\"")
            generator.appendRaw("")
        }

        // 4. Pre-cache tree and start background refresh
        cachedTree = try? bridge.tree()
        startTreeCacheRefresh()

        // 5. Start getevent process
        try startGetEvent()

        print("Recording... Interact with the device. Press Ctrl+C to stop.\n")
        // #133: getevent lee del kernel — el input sintético (auto-android tap,
        // adb shell input tap, UiAutomation) se inyecta a nivel InputManager y
        // NUNCA pasa por /dev/input, así que el recorder no lo ve por diseño.
        print("Nota: solo se graban toques reales en el device/emulador.")
        print("      Los taps del propio CLI (`auto-android tap`) no se graban — usa toques reales.\n")
    }

    public func stop() throws -> String {
        // Stop getevent and cache timer
        let hadProcess = getEventProcess != nil
        getEventProcess?.interrupt()
        getEventProcess?.waitUntilExit()
        getEventProcess = nil
        treeCacheTimer?.cancel()
        treeCacheTimer = nil

        // #133: esperar a que el reader thread termine de drenar el pipe.
        // waitUntilExit() solo garantiza que adb murió — los bytes ya escritos
        // al pipe pueden seguir sin procesar. Sin esta espera, el último tap
        // podía encolarse en resolveQueue DESPUÉS del flush (o después de
        // escribir el archivo) y desaparecer en silencio.
        if hadProcess {
            _ = readerDrained.wait(timeout: .now() + 2.0)
        }

        // Flush pending — corre después de todos los handleTouchEvent encolados
        // por el reader (resolveQueue es serial).
        resolveQueue.sync {
            flushPendingTap()
            // #54: si la grabación termina con el teclado abierto, cerrar la
            // sesión de tecleo pendiente para no perder el texto escrito.
            finalizeKeyboardCapture(treeAtGesture: nil)
        }

        // Write script
        let script = generator.render()
        try script.write(toFile: outputPath, atomically: true, encoding: .utf8)

        // #133: reportar comandos ejecutables, no líneas del buffer — lineCount
        // incluía la línea en blanco del header y mentía ("3 lines" / 2 comandos).
        let count = generator.commandCount
        print("\n\(count) command(s) recorded → \(outputPath)")

        return outputPath
    }

    // MARK: - getevent Process

    private func startGetEvent() throws {
        let adbPath = try findAdb()
        let deviceArgs = try getDeviceArgs()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = deviceArgs + ["shell", "getevent", "-lt"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // Read output line by line on a background thread
        let fileHandle = pipe.fileHandleForReading
        let parserRef = parser!
        let sessionRef = self

        DispatchQueue.global(qos: .userInitiated).async {
            var buffer = ""
            func process(_ lines: [String]) {
                for line in lines {
                    if let event = parserRef.parseLine(line) {
                        sessionRef.resolveQueue.async {
                            sessionRef.handleTouchEvent(event)
                        }
                    }
                }
            }
            while true {
                let data = fileHandle.availableData
                if data.isEmpty { break } // EOF

                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                buffer += chunk
                process(Self.extractLines(from: &buffer))
            }
            // #133: EOF — drenar la línea parcial final (getevent muere por
            // SIGINT a mitad de línea y el `\n` de cierre nunca llega).
            process(Self.extractLines(from: &buffer, flush: true))
            // Señalar a stop() que TODOS los eventos ya están encolados
            // en resolveQueue (el async de arriba corre antes que el
            // resolveQueue.sync del flush porque la cola es serial).
            sessionRef.readerDrained.signal()
        }

        try process.run()
        getEventProcess = process
    }

    // MARK: - Tree Cache

    private func startTreeCacheRefresh() {
        let timer = DispatchSource.makeTimerSource(queue: resolveQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.refreshTreeCache()
        }
        timer.resume()
        treeCacheTimer = timer
    }

    private func refreshTreeCache() {
        if let tree = try? bridge.tree(), !tree.isEmpty {
            cachedTree = tree
            // #54: mientras hay sesión de tecleo, trackear el value del campo
            // enfocado — fallback si al finalizar el campo perdió el foco.
            if keyboardActive,
               let value = AndroidRecorderDetection.focusedEditableValue(in: tree) {
                keyboardValueLatest = value
            }
        }
    }

    // MARK: - Touch Event Handling

    private func handleTouchEvent(_ event: AndroidRawEvent) {
        switch event.phase {
        case .down(let x, let y):
            handleTouchDown(x: x, y: y, timestamp: event.timestamp)

        case .move(let x, let y):
            lastMovePoint = (x, y)

        case .up:
            handleTouchUp(timestamp: event.timestamp)
        }
    }

    private func handleTouchDown(x: Int, y: Int, timestamp: Double) {
        touchDownPoint = (x, y)
        touchDownTimestamp = timestamp
        lastMovePoint = (x, y)

        // Use pre-cached tree (avoids 2s uiautomator dump at touch time)
        touchDownTree = cachedTree

        // Schedule tree refresh AFTER this touch processes
        resolveQueue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshTreeCache()
        }
    }

    private func handleTouchUp(timestamp: Double) {
        // #133: el tree NO es requisito para procesar el gesto. Antes el guard
        // exigía `touchDownTree != nil` y descartaba el touch completo en
        // silencio si el cache estaba vacío (p.ej. bridge.tree() falló al
        // arrancar y el refresh de 1s aún no corría) — incluso swipes, que ni
        // usan el tree. Ahora: swipe siempre se emite; tap/longPress sin tree
        // caen a `tapAt x y` en vez de perderse.
        guard let downPoint = touchDownPoint else { return }
        let tree = touchDownTree

        let upPoint = lastMovePoint ?? downPoint
        let duration = timestamp - touchDownTimestamp
        let dx = abs(upPoint.x - downPoint.x)
        let dy = abs(upPoint.y - downPoint.y)
        let distance = sqrt(Double(dx * dx + dy * dy))

        // Reset state
        touchDownPoint = nil
        touchDownTree = nil
        lastMovePoint = nil

        // #54: toques sobre el teclado virtual — el más fresco entre el tree
        // del touch-down y el cache (el IME puede haber aparecido después de
        // la última captura del touch-down).
        let imeTree = tree ?? cachedTree
        let insideIME = imeTree.map {
            AndroidRecorderDetection.isPointInsideIME(x: downPoint.x, y: downPoint.y, tree: $0)
        } ?? false
        let imeCacheTree = cachedTree.flatMap {
            AndroidRecorderDetection.isPointInsideIME(x: downPoint.x, y: downPoint.y, tree: $0) ? $0 : nil
        }

        // Classify gesture
        switch Self.classifyGesture(distance: distance, duration: duration) {
        case .swipe:
            if insideIME || imeCacheTree != nil {
                // Glide typing / swipe dentro del teclado: parte del tecleo
                beginKeyboardCaptureIfNeeded(tree: tree ?? imeCacheTree)
                return
            }
            finalizeKeyboardCapture(treeAtGesture: tree)
            handleSwipe(from: downPoint, to: upPoint)
        case .longPress:
            if insideIME || imeCacheTree != nil {
                // Long press en tecla (acentos, símbolos) — sigue siendo tecleo
                beginKeyboardCaptureIfNeeded(tree: tree ?? imeCacheTree)
                return
            }
            finalizeKeyboardCapture(treeAtGesture: tree)
            let action = Self.resolveTouchOrFallback(
                x: downPoint.x, y: downPoint.y, tree: tree, command: "longPress"
            )
            emitAction(action, timestamp: timestamp)
        case .tap:
            if insideIME || imeCacheTree != nil {
                // Para detectar la tecla Enter se necesita el tree que SÍ
                // contiene la ventana IME; para el value inicial, el tree
                // del touch-down (previo al keypress).
                handleKeyboardTap(x: downPoint.x, y: downPoint.y,
                                  gestureTree: tree ?? imeCacheTree,
                                  imeTree: (insideIME ? imeTree : nil) ?? imeCacheTree)
                return
            }
            finalizeKeyboardCapture(treeAtGesture: tree)

            let action = Self.resolveTouchOrFallback(
                x: downPoint.x, y: downPoint.y, tree: tree, command: "tap"
            )
            handlePotentialDoubleTap(action: action, timestamp: timestamp)
        }
    }

    // MARK: - #54: Keyboard Capture

    /// Tap dentro de la ventana IME: arranca/continúa la sesión de tecleo.
    /// Si el toque cayó sobre una tecla Enter expuesta al tree, cierra la
    /// sesión (emite el `type`) y agrega `pressKey enter`.
    private func handleKeyboardTap(x: Int, y: Int,
                                   gestureTree: [[String: Any]]?,
                                   imeTree: [[String: Any]]?) {
        if let imeTree, keyboardActive,
           AndroidRecorderDetection.isEnterKeyTap(x: x, y: y, tree: imeTree) {
            finalizeKeyboardCapture(treeAtGesture: imeTree)
            let line = "pressKey enter"
            generator.appendRaw(line)
            printRecorded(line)
            return
        }
        beginKeyboardCaptureIfNeeded(tree: gestureTree)
    }

    private func beginKeyboardCaptureIfNeeded(tree: [[String: Any]]?) {
        guard !keyboardActive else { return }
        keyboardActive = true
        // Value del campo enfocado ANTES del primer keypress: el tree del
        // touch-down se capturó antes de que la tecla aplicara su carácter.
        keyboardValueBefore = tree.flatMap {
            AndroidRecorderDetection.focusedEditableValue(in: $0)
        } ?? ""
        keyboardValueLatest = nil
        printRecorded("# teclado virtual detectado — acumulando tecleo…")
    }

    /// Cierra la sesión de tecleo: lee el value final del campo enfocado y
    /// emite los comandos del diff (`type` / `eraseText`). Orden de fuentes
    /// para el value final: tree fresco del bridge → tree del gesto que cerró
    /// la sesión → último value visto por el refresh del cache.
    private func finalizeKeyboardCapture(treeAtGesture: [[String: Any]]?) {
        guard keyboardActive else { return }
        keyboardActive = false

        let freshValue = (try? bridge.tree()).flatMap {
            AndroidRecorderDetection.focusedEditableValue(in: $0)
        }
        let gestureValue = treeAtGesture.flatMap {
            AndroidRecorderDetection.focusedEditableValue(in: $0)
        }
        let after = freshValue ?? gestureValue ?? keyboardValueLatest

        let commands = AndroidRecorderDetection.typingCommands(
            before: keyboardValueBefore, after: after
        )
        keyboardValueBefore = nil
        keyboardValueLatest = nil

        // Si hay un tap buffereado (detección de double-tap), emitirlo ANTES
        // del type para preservar el orden real de los gestos en el script.
        if !commands.isEmpty { flushPendingTap() }

        for line in commands {
            generator.appendRaw(line)
            printRecorded(line)
        }
    }

    // MARK: - Gesture Classification (pure, testable)

    public enum GestureKind: Equatable {
        case tap
        case longPress
        case swipe
    }

    /// Clasifica un gesto por distancia recorrida (px) y duración (s).
    /// Función pura para poder testearla sin getevent real.
    public static func classifyGesture(distance: Double, duration: Double) -> GestureKind {
        if distance > 50 { return .swipe }
        if duration > 0.5 { return .longPress }
        return .tap
    }

    /// Resuelve un touch contra el tree, o cae a `tapAt x y` si no hay tree.
    /// #133: perder la línea entera era peor que grabar coordenadas crudas.
    public static func resolveTouchOrFallback(
        x: Int, y: Int, tree: [[String: Any]]?, command: String
    ) -> ResolvedAction {
        if let tree {
            return AndroidSemanticResolver.resolveTouch(x: x, y: y, tree: tree, command: command)
        }
        return ResolvedAction(
            command: "tapAt",
            selector: "\(x) \(y)",
            role: nil, within: nil, occurrence: nil,
            identifier: nil, fragile: true,
            coordinate: CGPoint(x: CGFloat(x), y: CGFloat(y))
        )
    }

    /// Extrae las líneas completas de `buffer`, dejando la línea parcial final
    /// dentro del buffer. Con `flush: true` (EOF) devuelve también el residuo.
    /// Estática y pura para testearla sin pipe real (#133).
    public static func extractLines(from buffer: inout String, flush: Bool = false) -> [String] {
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: "\n") {
            lines.append(String(buffer[buffer.startIndex..<newline]))
            buffer = String(buffer[buffer.index(after: newline)...])
        }
        if flush && !buffer.isEmpty {
            lines.append(buffer)
            buffer = ""
        }
        return lines
    }

    // MARK: - Gesture Helpers

    private func handleSwipe(from: (x: Int, y: Int), to: (x: Int, y: Int)) {
        let dx = to.x - from.x
        let dy = to.y - from.y

        let direction: String
        if abs(dx) > abs(dy) {
            direction = dx > 0 ? "right" : "left"
        } else {
            direction = dy > 0 ? "down" : "up"
        }

        let line = "swipe \(direction)"
        generator.appendRaw(line)
        printRecorded(line)

        // Auto-inject wait after swipe so the AX tree settles before next tap (#63)
        let waitLine = "wait 0.5"
        generator.appendRaw(waitLine)
        printRecorded(waitLine)
    }

    private func handlePotentialDoubleTap(action: ResolvedAction, timestamp: Double) {
        // Check if this is a double tap (same selector within 300ms)
        if let pending = pendingTap,
           timestamp - pending.timestamp < 0.3,
           pending.action.selector == action.selector {
            pendingTapWork?.cancel()
            pendingTap = nil
            pendingTapWork = nil

            let doubleTapAction = ResolvedAction(
                command: "doubleTap",
                selector: action.selector,
                role: action.role, within: action.within,
                occurrence: action.occurrence,
                identifier: action.identifier,
                fragile: action.fragile,
                coordinate: action.coordinate
            )
            emitAction(doubleTapAction, timestamp: timestamp)
            return
        }

        // Buffer this tap for 300ms
        pendingTap = (action: action, timestamp: timestamp)
        let work = DispatchWorkItem { [weak self] in
            self?.flushPendingTap()
        }
        pendingTapWork = work
        resolveQueue.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func flushPendingTap() {
        guard let pending = pendingTap else { return }
        pendingTapWork?.cancel()
        pendingTap = nil
        pendingTapWork = nil
        emitAction(pending.action, timestamp: pending.timestamp)
    }

    // MARK: - Emit

    private func emitAction(_ action: ResolvedAction, timestamp: Double) {
        // Auto-inject scrollUntilVisible if the tapped element exists in the tree
        // but is offscreen. Without this, replay fails because uiautomator dump
        // returns offscreen elements.
        if action.command == "tap" && !action.selector.isEmpty {
            injectScrollIfOffscreen(for: action)
        }

        let outputLines = generator.process(action, uiChanges: 0, timestamp: timestamp)
        for line in outputLines {
            printRecorded(line)
        }
    }

    /// Emit `scrollUntilVisible "selector"` if the target element is currently
    /// outside the viewport. Uses the cached tree (refreshed every 1s) to avoid
    /// the 2s `uiautomator dump` penalty per tap.
    private func injectScrollIfOffscreen(for action: ResolvedAction) {
        guard let tree = cachedTree,
              let screen = try? bridge.viewport(),
              let line = RecorderScrollHelper.scrollLine(forSelector: action.selector,
                                                         in: tree,
                                                         viewport: screen) else {
            return
        }
        generator.appendRaw(line)
        printRecorded(line)
    }

    private func printRecorded(_ line: String) {
        if line.hasPrefix("#") {
            print("       \(line)")
        } else {
            print("[REC]  \(line)")
        }
    }

    // MARK: - ADB Helpers

    private func findAdb() throws -> String {
        // Check ANDROID_HOME
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            let path = home + "/platform-tools/adb"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Check ANDROID_SDK_ROOT
        if let root = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            let path = root + "/platform-tools/adb"
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        // Check PATH
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["adb"]
        let pipe = Pipe()
        which.standardOutput = pipe
        try which.run()
        which.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !output.isEmpty && FileManager.default.fileExists(atPath: output) {
            return output
        }
        throw BridgeError.adbNotFound
    }

    private func getDeviceArgs() throws -> [String] {
        // If a device is selected, add -s flag
        if let deviceId = AutoPilotConfig.get("device") {
            return ["-s", deviceId]
        }
        return []
    }

    private func getTouchCalibration() throws -> TouchCalibration {
        let adbPath = try findAdb()
        let deviceArgs = try getDeviceArgs()

        // Get getevent -p (input device properties)
        let getEventInfo = try runAdbCommand(adbPath, args: deviceArgs + ["shell", "getevent", "-p"])

        // Get screen size
        let wmSize = try runAdbCommand(adbPath, args: deviceArgs + ["shell", "wm", "size"])

        guard let calibration = TouchCalibration.parse(getEventInfo: getEventInfo, wmSize: wmSize) else {
            // Fallback: use common emulator defaults
            return TouchCalibration(
                minX: 0, maxX: 32767,
                minY: 0, maxY: 32767,
                screenWidth: 1080, screenHeight: 2400
            )
        }
        return calibration
    }

    /// Detect the current foreground Android app package.
    private func detectForegroundApp() -> String? {
        guard let adbPath = try? findAdb(),
              let deviceArgs = try? getDeviceArgs() else { return nil }
        // dumpsys activity recents gives the top activity
        guard let output = try? runAdbCommand(adbPath, args: deviceArgs + ["shell", "dumpsys", "activity", "recents"]) else { return nil }
        // Look for "realActivity=com.example.app/..." or "baseActivity=com.example.app/..."
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("realActivity=") || trimmed.contains("baseActivity=") {
                // Extract package: "realActivity={com.example.app/.MainActivity}"
                if let eqIdx = trimmed.range(of: "Activity="),
                   let slashIdx = trimmed[eqIdx.upperBound...].firstIndex(of: "/") {
                    var pkg = String(trimmed[eqIdx.upperBound..<slashIdx])
                    // Strip braces: "{com.example.app" → "com.example.app"
                    pkg = pkg.replacingOccurrences(of: "{", with: "")
                        .replacingOccurrences(of: "}", with: "")
                    // Skip launcher and system apps
                    if !pkg.contains("launcher") && !pkg.contains("android.intent") {
                        return pkg
                    }
                }
            }
        }
        return nil
    }

    private func runAdbCommand(_ adbPath: String, args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
