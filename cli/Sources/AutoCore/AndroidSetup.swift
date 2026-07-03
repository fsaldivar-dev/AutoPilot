import Foundation

/// `auto-android setup` — Bootstrap completo idempotente Android.
/// Paridad con `auto setup` iOS.
///
/// **Respeta el paradigma Command + Capability Discovery (ARD-001):** las
/// acciones de device (list devices, boot probe) viajan por el `ActionRouter`.
/// Solo bootstrap de entorno (adb forward, am instrument, emulator launch,
/// apk install) usa Process/AgentBridge directo — no son device actions.
///
/// Pasos idempotentes:
///   1. Detectar ADB disponible                          [env — Process]
///   2. Detectar dispositivo conectado                   [router → .listDevices]
///   3. Si no hay, intentar bootear emulador del config  [env — emulator]
///   4. Install APK del agente si no está                [env — adb install]
///   5. Adb forward + am instrument + probe socket       [agent.setupAgent]
///   6. Warmup via router                                [router → .search]
public enum AndroidSetup {

    public static func run(router: ActionRouter, bridge: any DeviceBridge) async throws {
        print("AutoPilot Setup — Android\n")

        // 1. ADB
        try ensureAdbAvailable()

        // 2+3. Device connected (router → .listDevices)
        _ = try await ensureDeviceConnected(router: router)

        // 4. Agent APK installed
        try ensureAgentApkInstalled()

        // 5. Forward + instrument (via AgentBridge existente)
        try ensureAgentRunning(bridge: bridge)

        // 6. Warmup via router
        await warmupRouter(router: router)

        print("\n✓ Setup complete — try: auto-android list buttons")
    }

    // MARK: - Step 1: ADB available

    private static func ensureAdbAvailable() throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["adb", "version"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw BridgeError.adbNotFound
        }
        print("✓ adb available")
    }

    // MARK: - Step 2+3: Device via router, boot emulator if empty

    private static func ensureDeviceConnected(router: ActionRouter) async throws -> String {
        let result = try await router.execute(.listDevices)
        if case .deviceList(let devs) = result {
            if let booted = devs.first(where: { ($0["state"] as? String) == "Booted" }),
               let udid = booted["udid"] as? String {
                print("✓ Device connected (\(udid))")
                return udid
            }
        }

        // Ningún device booteado — intentar emulator del .autopilot
        let config = AutoPilotConfig.readAll()
        guard let avd = config["emulator"] ?? config["avd"] else {
            throw BridgeError.adbFailed("No device connected and no 'emulator' set in .autopilot")
        }

        print("→ Booting emulator '\(avd)' (takes ~20s)...")
        try bootEmulator(avdName: avd)

        // Poll via router
        for _ in 0..<60 {
            let r = try? await router.execute(.listDevices)
            if case .deviceList(let devs) = r,
               let booted = devs.first(where: { ($0["state"] as? String) == "Booted" }),
               let udid = booted["udid"] as? String {
                print("✓ Emulator booted (\(udid))")
                return udid
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        throw BridgeError.adbFailed("Emulator did not reach booted state after 60s")
    }

    /// Reutilizado por `AdbLegacyBridge.bootDevice` (#136) — por eso es
    /// internal y no private.
    static func bootEmulator(avdName: String) throws {
        // Validar nombre — emulator acepta [A-Za-z0-9_.-]
        guard avdName.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }) else {
            throw BridgeError.adbFailed("Invalid AVD name: \(avdName)")
        }

        // Detached: `emulator` es long-running, lo lanzamos sin esperar.
        // Process.arguments array → cero shell interpretation.
        let proc = emulatorProcess(arguments: ["-avd", avdName, "-no-snapshot-load"])
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.standardInput = FileHandle.nullDevice
        try proc.run()
        // No waitUntilExit — el proceso es long-running. El polling de
        // ensureDeviceConnected va a confirmar cuando bootee.
    }

    /// Lista los AVDs disponibles via `emulator -list-avds`.
    /// Usado por `AdbLegacyBridge.bootDevice` para validar el nombre antes
    /// de lanzar y evitar el falso exito de #136.
    static func listAvds() throws -> [String] {
        let proc = emulatorProcess(arguments: ["-list-avds"])
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
        } catch {
            throw BridgeError.adbFailed("emulator binary not found — set ANDROID_HOME or add emulator to PATH")
        }
        proc.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard proc.terminationStatus == 0 else {
            throw BridgeError.adbFailed("emulator -list-avds failed (exit \(proc.terminationStatus)) — set ANDROID_HOME or add emulator to PATH")
        }
        // El emulator a veces imprime lineas informativas (INFO | ...) —
        // filtramos a nombres validos de AVD [A-Za-z0-9_.-]
        return out.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && line.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "." }
            }
    }

    /// Construye un Process para el binario `emulator` del SDK.
    /// Orden de resolucion: ANDROID_HOME, ANDROID_SDK_ROOT, ruta default de
    /// Android Studio en macOS, PATH via /usr/bin/env (mismo patron que
    /// `AdbLegacyBridge.adbPath`, #65).
    private static func emulatorProcess(arguments: [String]) -> Process {
        let proc = Process()

        var candidates: [String] = []
        if let home = ProcessInfo.processInfo.environment["ANDROID_HOME"] {
            candidates.append("\(home)/emulator/emulator")
        }
        if let root = ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"] {
            candidates.append("\(root)/emulator/emulator")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/Library/Android/sdk/emulator/emulator")

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = arguments
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["emulator"] + arguments
        }
        return proc
    }

    // MARK: - Step 4: Agent APK installed

    private static func ensureAgentApkInstalled() throws {
        // Probe: listar packages instalados en el device y ver si el agente está
        let check = Process()
        check.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        check.arguments = ["adb", "shell", "pm", "list", "packages", "dev.autopilot.agent"]
        let pipe = Pipe()
        check.standardOutput = pipe
        check.standardError = FileHandle.nullDevice
        try check.run()
        check.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if out.contains("dev.autopilot.agent") {
            print("✓ Agent APK already installed")
            return
        }

        // Buscar APK compilado en el repo
        let apkPath = findAgentApk()
        guard let apk = apkPath else {
            print("⚠ Agent APK not found in repo — skipping install")
            print("  Build with: cd agent && ./gradlew :app:assembleDebug")
            print("  (requiere ANDROID_HOME o agent/local.properties con sdk.dir)")
            return
        }

        print("→ Installing agent APK...")
        let install = Process()
        install.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        install.arguments = ["adb", "install", "-r", "-g", apk]
        install.standardOutput = FileHandle.nullDevice
        install.standardError = FileHandle.nullDevice
        try install.run()
        install.waitUntilExit()
        if install.terminationStatus == 0 {
            print("✓ Agent APK installed")
        } else {
            print("⚠ adb install returned \(install.terminationStatus) — agent may not work")
        }
    }

    private static func findAgentApk() -> String? {
        // Proyecto gradle en agent/, módulo :app — ver agent/settings.gradle.kts
        let apk = "\(RepoRoot.find())/agent/app/build/outputs/apk/debug/app-debug.apk"
        return FileManager.default.fileExists(atPath: apk) ? apk : nil
    }

    // MARK: - Step 5: Forward + instrument

    private static func ensureAgentRunning(bridge: any DeviceBridge) throws {
        guard let agent = bridge as? AgentBridge else {
            throw BridgeError.adbFailed("setup requires AgentBridge (not --legacy)")
        }
        agent.autoRecover = false  // evitamos recovery recursivo durante setup
        try agent.setupAgent(verbose: true)
    }

    // MARK: - Step 6: Warmup via router

    private static func warmupRouter(router: ActionRouter) async {
        print("→ Warming up router...")
        _ = try? await router.execute(.search(query: "__autopilot_warmup_probe__"))
        print("✓ Router ready")
    }
}
