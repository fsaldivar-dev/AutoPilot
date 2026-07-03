import Foundation
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
