import Foundation
import CoreGraphics
import AutoCore

// MARK: - MediaEngine
//
// Captura de media y camera mock iOS. Extraído de `SimulatorBridge.swift` como
// parte de la "extracción física" post-ARD-001 — la API pública del bridge no
// cambia, el código solo vive en este archivo separado para facilitar reading
// y testing focalizado.
//
// Responsabilidades:
//   - `screenshot` / `addMedia` vía `xcrun simctl io`
//   - `startRecording` / `stopRecording` con state en SimulatorBridge
//   - `cameraStart/Feed/Stop/Status` vía filesystem (feed + signal files)
//   - `buildWithCameraMock` / `setInjectImage` / `injectAndLaunch` (DYLD inject)

extension SimulatorBridge {

    // MARK: Paths compartidos (fileprivate visibles en esta extension)

    /// Well-known path donde el mock dylib lee imágenes.
    public static let injectImagePath = "/tmp/autopilot-camera-image.jpg"

    internal static let cameraFeedPath = "/tmp/autopilot-camera-feed.jpg"
    internal static let cameraSignalPath = "/tmp/autopilot-camera-active"

    // MARK: - Screenshot

    /// Captura de pantalla del device (#155).
    ///
    /// Primario: `xcrun simctl io <udid> screenshot` — lee el FRAMEBUFFER del
    /// device a resolución nativa, independiente de dónde esté (o si es
    /// visible) la ventana del Simulator en el Mac.
    ///
    /// Fallback: `screencapture -l <windowID>` de la ventana del Simulator,
    /// solo si simctl falla (con aviso en stderr). Esta captura depende de la
    /// ventana del Mac y puede salir recortada si está tapada o fuera de
    /// pantalla — por eso es último recurso y nunca el path por defecto.
    public func screenshot(path: String) throws {
        // Sin device booteado no hay nada que capturar: propagar el error
        // claro de getBootedDeviceId en vez de caer a la ventana del Mac.
        let deviceId = try getBootedDeviceId()
        do {
            try screenshotViaSimctl(deviceId: deviceId, path: path)
        } catch {
            let reason: String
            if case BridgeError.simctlFailed(let msg) = error {
                reason = msg
            } else {
                reason = String(describing: error)
            }
            FileHandle.standardError.write(Data(
                ("warning: `simctl io screenshot` failed (\(reason)) — " +
                 "falling back to `screencapture` of the Simulator window; " +
                 "the image may be cropped if the window is occluded or off-screen\n").utf8))
            try screenshotViaWindowCapture(path: path)
        }
    }

    /// Framebuffer del device via `simctl io`. Resolución NATIVA del device
    /// (p.ej. 1179x2556 en un iPhone 15), no la de la ventana del Simulator.
    private func screenshotViaSimctl(deviceId: String, path: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "io", deviceId, "screenshot", path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw BridgeError.simctlFailed(
                "simctl io screenshot exited \(process.terminationStatus)"
                    + (msg.isEmpty ? "" : ": \(msg)"))
        }
    }

    /// Último recurso: captura la ventana del Simulator con `screencapture`.
    /// `-l <windowID>` captura esa ventana específica sin mover nada ni robar
    /// foco; `-x` sin sonido; `-o` sin sombra.
    private func screenshotViaWindowCapture(path: String) throws {
        guard let windowID = Self.simulatorWindowID() else {
            throw BridgeError.screenshotFailed
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(windowID), path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: path) else {
            throw BridgeError.screenshotFailed
        }
    }

    /// Window ID de la ventana principal (layer 0, la más grande) de
    /// Simulator.app, o nil si no hay ventana en pantalla.
    private static func simulatorWindowID() -> CGWindowID? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID)
                as? [[String: Any]] else { return nil }

        func area(_ window: [String: Any]) -> CGFloat {
            guard let dict = window[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict) else { return 0 }
            return rect.width * rect.height
        }

        return list
            .filter {
                ($0[kCGWindowOwnerName as String] as? String) == "Simulator"
                    && ($0[kCGWindowLayer as String] as? Int) == 0
            }
            .max { area($0) < area($1) }
            .flatMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    // MARK: - Add Media (simctl addmedia)

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

    // MARK: - Screen Recording (issue #125: estado persistido en /tmp, no en memoria)
    //
    // `startRecording`/`stopRecording` funcionan como comandos CLI sueltos:
    // el proceso `simctl recordVideo` se lanza detached (sobrevive al CLI) y su
    // PID + path temporal se persisten vía RecordingStateStore. `stop` en otra
    // invocación (u otro proceso) lee el archivo, manda SIGINT y mueve el mp4.

    public func startRecording() throws {
        let deviceId = try getBootedDeviceId()
        let store = RecordingStateStore()

        if let existing = store.load(deviceId: deviceId) {
            if RecordingStateStore.isProcessAlive(existing.pid) {
                throw BridgeError.recordingAlreadyInProgress(deviceId)
            }
            // Estado huérfano (el grabador murió sin stop): limpiar y continuar.
            try? FileManager.default.removeItem(atPath: existing.tempPath)
            store.clear(deviceId: deviceId)
        }

        let tempPath = NSTemporaryDirectory() + "autopilot-recording-\(UUID().uuidString).mp4"
        let command = "/usr/bin/xcrun simctl io \(DetachedProcess.shellQuote(deviceId)) "
            + "recordVideo --codec=h264 \(DetachedProcess.shellQuote(tempPath))"
        let pid = try DetachedProcess.launch(command)

        // Sanity check: si recordVideo murió al instante (device apagándose,
        // path no escribible), reportarlo ya en vez de fallar en el stop.
        usleep(300_000)
        guard RecordingStateStore.isProcessAlive(pid) else {
            throw BridgeError.simctlFailed("recordVideo exited immediately — is the simulator booted?")
        }

        try store.save(RecordingState(pid: pid, deviceId: deviceId, tempPath: tempPath))
    }

    public func stopRecording(outputPath: String) throws {
        let deviceId = try getBootedDeviceId()
        let store = RecordingStateStore()
        guard let state = store.load(deviceId: deviceId) else {
            throw BridgeError.noRecordingInProgress
        }

        if RecordingStateStore.isProcessAlive(state.pid) {
            // SIGINT: simctl recordVideo finaliza el mp4 (moov atom) y sale.
            kill(state.pid, SIGINT)
            // Esperar el flush — el proceso muere cuando terminó de escribir.
            let deadline = Date().addingTimeInterval(15)
            while RecordingStateStore.isProcessAlive(state.pid) && Date() < deadline {
                usleep(100_000)
            }
        }

        let fm = FileManager.default
        guard fm.fileExists(atPath: state.tempPath) else {
            store.clear(deviceId: deviceId)
            throw BridgeError.simctlFailed("Recording produced no video file (\(state.tempPath))")
        }
        if fm.fileExists(atPath: outputPath) {
            try fm.removeItem(atPath: outputPath)
        }
        try fm.moveItem(atPath: state.tempPath, toPath: outputPath)
        store.clear(deviceId: deviceId)
    }

    // MARK: - Virtual Camera (feed + signal files)

    /// Start virtual camera with an image.
    public func cameraStart(imagePath: String) throws {
        let source = URL(fileURLWithPath: imagePath)
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw BridgeError.cameraImageNotFound(imagePath)
        }

        let dest = URL(fileURLWithPath: Self.cameraFeedPath)
        if FileManager.default.fileExists(atPath: Self.cameraFeedPath) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: source, to: dest)

        // Crear archivo signal
        FileManager.default.createFile(atPath: Self.cameraSignalPath, contents: nil)
    }

    /// Update the camera feed image.
    public func cameraFeed(imagePath: String) throws {
        guard FileManager.default.fileExists(atPath: imagePath) else {
            throw BridgeError.cameraImageNotFound(imagePath)
        }

        let dest = URL(fileURLWithPath: Self.cameraFeedPath)
        if FileManager.default.fileExists(atPath: Self.cameraFeedPath) {
            try FileManager.default.removeItem(at: dest)
        }
        try FileManager.default.copyItem(at: URL(fileURLWithPath: imagePath), to: dest)
    }

    /// Stop the virtual camera.
    public func cameraStop() {
        try? FileManager.default.removeItem(atPath: Self.cameraSignalPath)
        try? FileManager.default.removeItem(atPath: Self.cameraFeedPath)
    }

    /// Check if virtual camera is active.
    public func cameraStatus() -> (active: Bool, imagePath: String?) {
        let active = FileManager.default.fileExists(atPath: Self.cameraSignalPath)
        let hasImage = FileManager.default.fileExists(atPath: Self.cameraFeedPath)
        return (active: active, imagePath: hasImage ? Self.cameraFeedPath : nil)
    }

    // MARK: - Build (xcodebuild + camera mock VFS overlay)

    /// Builds an Xcode project with camera mock injected via VFS overlay.
    public func buildWithCameraMock(args: [String]) throws {
        let interceptor = BuildInterceptor()
        try interceptor.build(args: args)
    }

    // MARK: - Inject (dylib — DYLD_INSERT_LIBRARIES)

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
        try launchWithDylibs(
            bundleId: bundleId,
            dylibPaths: [try DylibInjector().ensureDylib()],
            extraEnv: extraEnv,
            setupBeforeLaunch: {
                if let img = imagePath { try self.setInjectImage(img) }
            }
        )
    }

    /// Launches the app with libAutoPilotObserver.dylib injected. Once attached,
    /// the observer answers AX queries over TCP :7002 — `tree`/`inspect`/etc. no
    /// longer depend on Simulator.app being frontmost.
    ///
    /// Simulator-only: iOS device sandbox blocks DYLD injection. Device uses
    /// the static lib with `-force_load` at build time (see BuildInterceptor).
    public func injectObserverAndLaunch(bundleId: String, extraEnv: [String: String] = [:]) throws {
        try launchWithDylibs(
            bundleId: bundleId,
            dylibPaths: [try ObserverInjector().ensureDylib()],
            extraEnv: extraEnv
        )
    }

    /// Camera + observer combinados en un único launch (multi-dylib injection).
    public func injectCameraAndObserverAndLaunch(
        bundleId: String,
        imagePath: String?,
        extraEnv: [String: String] = [:]
    ) throws {
        let cameraDylib = try DylibInjector().ensureDylib()
        let observerDylib = try ObserverInjector().ensureDylib()
        try launchWithDylibs(
            bundleId: bundleId,
            dylibPaths: [cameraDylib, observerDylib],
            extraEnv: extraEnv,
            setupBeforeLaunch: {
                if let img = imagePath { try self.setInjectImage(img) }
            }
        )
    }

    // MARK: - Shared dylib injection path

    private func launchWithDylibs(
        bundleId: String,
        dylibPaths: [String],
        extraEnv: [String: String],
        setupBeforeLaunch: (() throws -> Void)? = nil
    ) throws {
        try setupBeforeLaunch?()

        let deviceId = try getBootedDeviceId()

        // Terminate if running (ignore errors — app may not be running)
        let term = Process()
        term.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        term.arguments = ["simctl", "terminate", deviceId, bundleId]
        try? term.run()
        term.waitUntilExit()

        // DYLD_INSERT_LIBRARIES acepta múltiples dylibs separadas por ":".
        var env = ProcessInfo.processInfo.environment
        env["SIMCTL_CHILD_DYLD_INSERT_LIBRARIES"] = dylibPaths.joined(separator: ":")

        for (key, value) in extraEnv {
            env["SIMCTL_CHILD_\(key)"] = value
        }

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
