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
    }

    public func stop() throws -> String {
        // Stop getevent and cache timer
        getEventProcess?.interrupt()
        getEventProcess?.waitUntilExit()
        getEventProcess = nil
        treeCacheTimer?.cancel()
        treeCacheTimer = nil

        // Flush pending
        resolveQueue.sync {
            flushPendingTap()
        }

        // Write script
        let script = generator.render()
        try script.write(toFile: outputPath, atomically: true, encoding: .utf8)

        let count = generator.lineCount
        print("\n\(count) line(s) recorded → \(outputPath)")

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
            while true {
                let data = fileHandle.availableData
                if data.isEmpty { break } // EOF

                guard let chunk = String(data: data, encoding: .utf8) else { continue }
                buffer += chunk

                // Process complete lines
                while let newline = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<newline])
                    buffer = String(buffer[buffer.index(after: newline)...])

                    if let event = parserRef.parseLine(line) {
                        sessionRef.resolveQueue.async {
                            sessionRef.handleTouchEvent(event)
                        }
                    }
                }
            }
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
        guard let downPoint = touchDownPoint,
              let tree = touchDownTree else { return }

        let upPoint = lastMovePoint ?? downPoint
        let duration = timestamp - touchDownTimestamp
        let dx = abs(upPoint.x - downPoint.x)
        let dy = abs(upPoint.y - downPoint.y)
        let distance = sqrt(Double(dx * dx + dy * dy))

        // Reset state
        touchDownPoint = nil
        touchDownTree = nil
        lastMovePoint = nil

        // Classify gesture
        if distance > 50 {
            // Swipe gesture
            handleSwipe(from: downPoint, to: upPoint)
        } else if duration > 0.5 {
            // Long press
            let action = AndroidSemanticResolver.resolveTouch(
                x: downPoint.x, y: downPoint.y, tree: tree, command: "longPress"
            )
            emitAction(action, timestamp: timestamp)
        } else {
            // Tap — check for double tap
            let action = AndroidSemanticResolver.resolveTouch(
                x: downPoint.x, y: downPoint.y, tree: tree, command: "tap"
            )
            handlePotentialDoubleTap(action: action, timestamp: timestamp)
        }
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
        let outputLines = generator.process(action, uiChanges: 0, timestamp: timestamp)
        for line in outputLines {
            printRecorded(line)
        }
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
