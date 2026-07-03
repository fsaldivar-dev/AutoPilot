import Foundation
import AutoCore

/// `auto setup` — Bootstrap completo idempotente del entorno iOS.
///
/// **Respeta el paradigma Command + Capability Discovery (ARD-001):** todas
/// las acciones de device (boot, check device state) viajan como `Action`
/// por el `ActionRouter`. Solo el bootstrap de entorno (abrir Simulator.app,
/// compilar runner, filesystem workarounds, daemon lifecycle) usa Process
/// directamente — no son device actions.
///
/// Pasos idempotentes:
///   1. Abre Simulator.app si no está corriendo          [env — Process]
///   2. Bootea device si no hay ninguno                  [router → .bootDevice]
///   3. Compila Runner XCTest si falta                   [env — xcodebuild]
///   4. Instala runner + workaround Xcode 26             [env — filesystem]
///   5. Arranca autopilotd con test ID correcto          [env — Process]
///   6. Warmup del runner                                [router → .search]
public enum iOSSetup {

    public static func run(router: ActionRouter) async throws {
        print("AutoPilot Setup — iOS\n")

        // 1. Simulator.app
        ensureSimulatorAppRunning()

        // 2. Simulador booteado (vía router — respeta capability discovery)
        let udid = try await ensureDeviceBooted(router: router)

        // 3. Runner compilado
        let runnerAppPath = try ensureRunnerBuilt(udid: udid)

        // 4. Runner instalado + workaround Xcode 26
        try ensureRunnerInstalled(runnerAppPath: runnerAppPath, udid: udid)

        // 5. Daemon corriendo con el test ID correcto
        try ensureDaemonRunning(udid: udid)

        // 6. Warmup (vía router — dispara escalation AX → XCUI)
        await warmupRunner(router: router)

        print("\n✓ Setup complete — try: auto list buttons")
    }

    // MARK: - Step 1: Simulator.app [environment]

    private static func ensureSimulatorAppRunning() {
        if isSimulatorAppRunning() {
            print("✓ Simulator.app already running")
            return
        }
        print("→ Opening Simulator.app...")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        proc.arguments = ["-a", "Simulator"]
        try? proc.run()
        proc.waitUntilExit()
        usleep(2_000_000)
        print("✓ Simulator.app opened")
    }

    private static func isSimulatorAppRunning() -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "Simulator"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - Step 2: Device booted [via router]

    private static func ensureDeviceBooted(router: ActionRouter) async throws -> String {
        // Consultar device id actual vía router — SimCtlBackend declara .getBootedDeviceId
        if let udid = try? await router.execute(.getBootedDeviceId).deviceId {
            print("✓ Device booted (\(udid))")
            return udid
        }

        let config = AutoPilotConfig.readAll()
        let target = config["device"] ?? config["simulator"] ?? "iPhone 17"

        print("→ Booting '\(target)' (via router.execute(.bootDevice))...")
        // Action.bootDevice → router → SimCtlBackend (porque declara .bootDevice)
        _ = try await router.execute(.bootDevice(target))

        // Poll vía router hasta que CoreSimulator publique el UDID
        for _ in 0..<50 {
            if let udid = try? await router.execute(.getBootedDeviceId).deviceId {
                print("✓ Device booted (\(udid))")
                return udid
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        throw BridgeError.noBootedDevice
    }

    // MARK: - Step 3: Runner built [environment — xcodebuild]

    private static func ensureRunnerBuilt(udid: String) throws -> String {
        if let path = findRunnerApp() {
            print("✓ Runner already built (\(URL(fileURLWithPath: path).lastPathComponent))")
            return path
        }

        print("→ Building runner (xcodebuild build-for-testing, ~30s)...")
        let repoRoot = RepoRoot.find()
        let proj = "\(repoRoot)/Demo/iOS/Test Automatitacion/Test Automatitacion.xcodeproj"

        guard FileManager.default.fileExists(atPath: proj) else {
            throw BridgeError.unknown("Runner project not found: \(proj) — run `auto setup` from inside the AutoPilot repo (no .git found walking up from the cwd)")
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
        proc.arguments = [
            "build-for-testing",
            "-project", proj,
            "-scheme", "Test Automatitacion",
            "-destination", "id=\(udid)",
            "-configuration", "Debug"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BridgeError.unknown("xcodebuild build-for-testing failed (code \(proc.terminationStatus))")
        }

        guard let path = findRunnerApp() else {
            throw BridgeError.unknown("Runner app not found after build")
        }
        print("✓ Runner built")
        return path
    }

    private static func findRunnerApp() -> String? {
        findInDerivedData(name: "Test AutomatitacionUITests-Runner.app", type: "d")
    }

    private static func findXctestrun() -> String? {
        findInDerivedData(name: "*.xctestrun", type: "f")?
            .split(separator: "\n")
            .map(String.init)
            .first(where: { $0.contains("Test_Automatitacion") })
    }

    private static func findInDerivedData(name: String, type: String) -> String? {
        let home = NSHomeDirectory()
        let derivedData = "\(home)/Library/Developer/Xcode/DerivedData"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/find")
        proc.arguments = [
            derivedData,
            "-name", name,
            "-type", type,
            "-not", "-path", "*/Index.noindex/*"
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.isEmpty ? nil : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Step 4: Runner installed + Xcode 26 workaround [env — filesystem]

    private static func ensureRunnerInstalled(runnerAppPath: String, udid: String) throws {
        let installer = RunnerInstaller()
        _ = try installer.installIfNeeded(sourceBundlePath: runnerAppPath, udid: udid)
        print("✓ Runner installed")

        guard let realXctestrun = findXctestrun() else {
            print("⚠ Could not find xctestrun in DerivedData — XCUI may not boot")
            return
        }

        let targetXctestrun = "\(RunnerInstaller.runnerBaseDir)/AutoPilotRunner.xctestrun"
        try? FileManager.default.removeItem(atPath: targetXctestrun)
        try FileManager.default.copyItem(atPath: realXctestrun, toPath: targetXctestrun)

        let derivedDir = (realXctestrun as NSString).deletingLastPathComponent
        let sourceDebugDir = "\(derivedDir)/Debug-iphonesimulator"
        let targetSymlink = "\(RunnerInstaller.runnerBaseDir)/Debug-iphonesimulator"
        try? FileManager.default.removeItem(atPath: targetSymlink)
        try FileManager.default.createSymbolicLink(
            atPath: targetSymlink,
            withDestinationPath: sourceDebugDir
        )
        print("✓ Xcode 26 xctestrun workaround applied")
    }

    // MARK: - Step 5: Daemon running [environment — sidecar lifecycle]

    private static func ensureDaemonRunning(udid: String) throws {
        let autoPath = resolveExecutablePath()
        let autoDir = URL(fileURLWithPath: autoPath).deletingLastPathComponent().path
        let daemonPath = "\(autoDir)/autopilotd"

        guard FileManager.default.fileExists(atPath: daemonPath) else {
            throw BridgeError.unknown("autopilotd not found at \(daemonPath)")
        }

        // Stop cualquier daemon previo para aplicar el env var correcto
        let stopProc = Process()
        stopProc.executableURL = URL(fileURLWithPath: daemonPath)
        stopProc.arguments = ["stop", "--udid", udid]
        stopProc.standardOutput = FileHandle.nullDevice
        stopProc.standardError = FileHandle.nullDevice
        try? stopProc.run()
        stopProc.waitUntilExit()
        usleep(500_000)

        print("→ Starting daemon...")
        let startProc = Process()
        startProc.executableURL = URL(fileURLWithPath: daemonPath)
        startProc.arguments = ["start", "--udid", udid, "--timeout", "600"]

        // El env var override es necesario porque el default de RunnerLifecycle
        // apunta a "AutoPilotRunnerUITests/..." pero el bundle instalado se
        // llama "Test AutomatitacionUITests".
        var env = ProcessInfo.processInfo.environment
        env["AUTOPILOT_RUNNER_TEST_ID"] = "Test AutomatitacionUITests/AutoPilotRunnerTests/testServe"
        startProc.environment = env

        startProc.standardOutput = FileHandle.nullDevice
        startProc.standardError = FileHandle.nullDevice
        try startProc.run()
        usleep(2_000_000)
        print("✓ Daemon running (pid=\(startProc.processIdentifier))")
    }

    // MARK: - Step 6: Warmup [via router]

    /// Dispara la primera acción que requiere el runner XCUI. Esto hace que
    /// el router escale AX → XCUI internamente y fuerza el boot del runner.
    /// El primer call cuesta ~12s, los siguientes ~400ms.
    private static func warmupRunner(router: ActionRouter) async {
        print("→ Warming up XCUI runner (first call ~12s)...")
        // `.search` con un query improbable: AX no lo encuentra → elementNotFound
        // → router escala a XCUIBackend → XCUIBackend conecta al runner → boot
        _ = try? await router.execute(.search(query: "__autopilot_warmup_probe__"))
        print("✓ XCUI runner ready")
    }

    // MARK: - Util

    private static func resolveExecutablePath() -> String {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size))
        guard _NSGetExecutablePath(&buf, &size) == 0 else {
            return CommandLine.arguments[0]
        }
        let raw = String(cString: buf)
        return (raw as NSString).resolvingSymlinksInPath
    }
}

// MARK: - ActionResult helpers

private extension ActionResult {
    var deviceId: String? {
        if case .deviceId(let id) = self { return id }
        return nil
    }
}
