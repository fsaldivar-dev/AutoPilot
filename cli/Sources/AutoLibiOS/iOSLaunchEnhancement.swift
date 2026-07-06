import Foundation
import AutoCore

/// Launch con integración a camera mock y parsing de flags (`--inject`, `--env`, `--recompile`).
/// iOS-específico porque depende de `SimulatorBridge.injectAndLaunch` y `DylibInjector`.
public enum iOSLaunchEnhancement {

    public static func execute(args: [String], simulatorBridge: SimulatorBridge, router: ActionRouter, start: CFAbsoluteTime) async throws {
        let config = AutoPilotConfig.readAll()
        let bundleId: String
        if args.count >= 2 && !args[1].hasPrefix("--") {
            bundleId = args[1]
        } else if let b = config["bundle"] {
            bundleId = b
        } else {
            printUsage()
            return
        }

        var envVars: [String: String] = [:]
        var injectImage: String? = nil
        var recompile = false
        // ARD #164: el observer se inyecta POR DEFECTO — es el motor sin robo
        // de foco (3.6ms/tap). Opt-out con --no-observer; --observer se acepta
        // por compatibilidad con scripts existentes.
        var withObserver = true

        if let img = config["image"] {
            envVars["AUTOPILOT_CAMERA_IMAGE"] = img
        }

        var i = args.count >= 2 && !args[1].hasPrefix("--") ? 2 : 1
        while i < args.count {
            if args[i] == "--env" && i + 1 < args.count {
                let pair = args[i + 1]
                if let eqIndex = pair.firstIndex(of: "=") {
                    let key = String(pair[pair.startIndex..<eqIndex])
                    let value = String(pair[pair.index(after: eqIndex)...])
                    envVars[key] = value
                }
                i += 2
            } else if args[i] == "--inject" {
                if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
                    injectImage = args[i + 1]
                    i += 2
                } else {
                    injectImage = config["image"]
                    i += 1
                }
            } else if args[i] == "--recompile" {
                recompile = true
                i += 1
            } else if args[i] == "--observer" {
                withObserver = true
                i += 1
            } else if args[i] == "--no-observer" {
                withObserver = false
                i += 1
            } else {
                i += 1
            }
        }

        if recompile {
            try DylibInjector().recompile()
            if withObserver { try ObserverInjector().recompile() }
        }

        // 4 combinaciones: {camera?, observer?} → dispatch al helper correcto.
        let imgPath: String? = injectImage.map { img in
            img.hasPrefix("/") ? img : FileManager.default.currentDirectoryPath + "/" + img
        }

        switch (imgPath, withObserver) {
        case (.some(let path), true):
            do {
                try simulatorBridge.injectCameraAndObserverAndLaunch(
                    bundleId: bundleId, imagePath: path, extraEnv: envVars)
                switch checkObserver(expected: bundleId) {
                case .live:
                    print("Launched \(bundleId) with camera + observer → \(path) (\(elapsedMs(start))ms)")
                case .hijacked(let other):
                    print("Launched \(bundleId) with camera mock → \(path) — ⚠ observer NO cargó en esta app: el socket 7002 responde desde '\(other)'; motor: XCUI runner (\(elapsedMs(start))ms)")
                case .dead:
                    print("Launched \(bundleId) with camera mock → \(path) — observer no cargó (¿app de sistema?); motor: XCUI runner (\(elapsedMs(start))ms)")
                }
            } catch {
                // ARD #164: la inyección del observer nunca debe bloquear el
                // launch — degradar a camera-only con aviso (queda XCUI runner)
                fputs("[observer] inyección falló (\(error)) — launch solo con camera mock; motor deep: XCUI runner\n", stderr)
                try simulatorBridge.injectAndLaunch(
                    bundleId: bundleId, imagePath: path, extraEnv: envVars)
                print("Launched \(bundleId) with camera mock → \(path) (\(elapsedMs(start))ms)")
            }
        case (.some(let path), false):
            try simulatorBridge.injectAndLaunch(
                bundleId: bundleId, imagePath: path, extraEnv: envVars)
            print("Launched \(bundleId) with camera mock → \(path) (\(elapsedMs(start))ms)")
        case (.none, true):
            do {
                try simulatorBridge.injectObserverAndLaunch(
                    bundleId: bundleId, extraEnv: envVars)
                // La inyección puede "succeed" pero el dylib no cargar (apps de
                // sistema rechazan DYLD_INSERT). Probar el socket para ser honesto,
                // Y verificar vía handshake QUÉ app tiene el puerto 7002 (#154).
                switch checkObserver(expected: bundleId) {
                case .live:
                    print("Launched \(bundleId) with observer (\(elapsedMs(start))ms)")
                case .hijacked(let other):
                    print("Launched \(bundleId) — ⚠ observer NO cargó en esta app: el socket 7002 responde desde '\(other)'; motor: XCUI runner (\(elapsedMs(start))ms)")
                case .dead:
                    print("Launched \(bundleId) — observer no cargó (¿app de sistema?); motor: XCUI runner (\(elapsedMs(start))ms)")
                }
            } catch {
                fputs("[observer] inyección falló (\(error)) — launch normal; motor deep: XCUI runner\n", stderr)
                _ = try await router.execute(.launchApp(bundleId: bundleId, envVars: envVars))
                print("Launched \(bundleId) (\(elapsedMs(start))ms)")
            }
        case (.none, false):
            // Launch vía router → SimCtlBackend (declara .launchApp).
            _ = try await router.execute(.launchApp(bundleId: bundleId, envVars: envVars))
            let ms = elapsedMs(start)
            if envVars.isEmpty {
                print("Launched \(bundleId) (\(ms)ms)")
            } else {
                print("Launched \(bundleId) with \(envVars.count) env var(s) (\(ms)ms)")
            }
        }
    }

    // MARK: - Observer post-launch check (#154)

    /// Resultado del probe post-launch: además de "¿responde el socket?",
    /// verifica QUÉ app lo tiene (el puerto 7002 es fijo).
    private enum ObserverProbeResult {
        /// El observer responde y corre en la app esperada (o es un dylib
        /// pre-handshake que no reporta bundleId — beneficio de la duda).
        case live
        /// El socket responde pero desde OTRA app — el observer NO cargó en
        /// la app lanzada; reportar "with observer" sería engañoso.
        case hijacked(by: String)
        /// Nadie responde en 7002.
        case dead
    }

    private static func checkObserver(expected: String) -> ObserverProbeResult {
        let agent = iOSAgentBridge()
        guard agent.probeSocketWithRetry(deadlineMs: 1500) else { return .dead }
        if let real = agent.observedBundleId(), real != expected {
            return .hijacked(by: real)
        }
        // #169: el observer responde el socket ANTES de que SwiftUI publique su
        // árbol de accesibilidad — el primer tree/list/exists tras launch salía
        // vacío (race de warm-up). Esperar (acotado ~1.2s) a que el árbol tenga
        // contenido real hace que la app quede consultable cuando launch retorna.
        settleObserverTree(agent: agent, deadlineMs: 1200)
        return .live
    }

    /// Poll del árbol del observer hasta que exponga algún elemento con label
    /// (no solo AXWindow/AXGroup contenedores) o venza el deadline. Best-effort.
    /// #197: poll a 50ms (antes 100ms) + deadline de reloj de pared real —
    /// el tree() del observer es ~ms, así que en el caso normal (app ya lista)
    /// sale en el primer poll; el poll fino recorta el tiempo hasta detectar
    /// que la app pintó su árbol. El deadline se mide contra CFAbsoluteTime
    /// para no depender de que tree() sea instantáneo.
    private static func settleObserverTree(agent: iOSAgentBridge, deadlineMs: Int) {
        let deadline = CFAbsoluteTimeGetCurrent() + Double(deadlineMs) / 1000.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            if let tree = try? agent.tree(), treeHasLabeledContent(tree) { return }
            usleep(50_000)
        }
    }

    private static func treeHasLabeledContent(_ nodes: [[String: Any]]) -> Bool {
        for node in nodes {
            let label = (node["label"] as? String) ?? ""
            let title = (node["title"] as? String) ?? ""
            if !label.isEmpty || !title.isEmpty { return true }
            if let children = node["children"] as? [[String: Any]],
               treeHasLabeledContent(children) { return true }
        }
        return false
    }

    private static func printUsage() {
        print("Usage: auto launch <bundleId> [--inject image.jpg] [--no-observer] [--env KEY=VALUE ...]")
        print("   or: auto config bundle com.example.app")
        print("       auto launch")
        print("")
        print("Flags:")
        print("  --inject [img]   Inyecta camera mock dylib al arrancar")
        print("  --observer       Inyecta libAutoPilotObserver.dylib (solo simulator)")
        print("                   → `tree`/`inspect` dejan de depender de Simulator.app foreground")
        print("  --env KEY=VALUE  Pasa env var al proceso del app")
        print("  --recompile      Fuerza recompilar dylib(s) antes de inyectar")
    }
}
