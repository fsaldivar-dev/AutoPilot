import Foundation
import ApplicationServices
import AutoCore

/// Diagnóstico del entorno iOS: Simulator.app, booted sim, xcrun, AX, env vars.
public enum iOSDoctor {

    public static func run(simulatorBridge: SimulatorBridge, bridge: any DeviceBridge) {
        print("AutoPilot Doctor — iOS Environment Check\n")

        print("Simulator.app:")
        if let pid = simulatorBridge.findSimulatorPID() {
            print("  ✓ Running (PID \(pid))")
        } else {
            print("  ✗ Not running — open Simulator.app first")
        }

        print("\nBooted Simulator:")
        do {
            // Consultar simctl (fuente autoritativa), no el bridge de UI: el
            // observer/HybridBridge lanza "not supported" para device-mgmt, lo
            // que daba el falso "No booted simulator" con un sim booteado (#154).
            let deviceId = try simulatorBridge.getBootedDeviceId()
            print("  ✓ \(deviceId)")
        } catch {
            print("  ✗ No booted simulator — run: xcrun simctl boot <device>")
        }

        print("\nxcrun:")
        let xcrunCheck = Process()
        xcrunCheck.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        xcrunCheck.arguments = ["--version"]
        let xcrunPipe = Pipe()
        xcrunCheck.standardOutput = xcrunPipe
        xcrunCheck.standardError = Pipe()
        try? xcrunCheck.run()
        xcrunCheck.waitUntilExit()
        if xcrunCheck.terminationStatus == 0 {
            let ver = (String(data: xcrunPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            print("  ✓ Found (\(ver))")
        } else {
            print("  ✗ xcrun not working — install Xcode Command Line Tools")
        }

        // ARD #164: AX ya no es parte del path default (robaba el foco) —
        // el permiso solo importa para los modos opt-in de debug.
        print("\nAccessibility Permission (solo AUTO_FORCE_AX=1 / AUTO_BRIDGE=simulator|hybrid):")
        if AXIsProcessTrusted() {
            print("  ✓ Granted")
        } else {
            print("  ○ Not granted — irrelevante para el path default (observer/XCUI)")
        }

        // ARD-002 Phase 5 (#116): reportar qué backend está activo
        print("\nBackend activo:")
        let observerProbe = iOSAgentBridge()
        if observerProbe.probeSocket() {
            // #154: el puerto 7002 es fijo — el handshake ping devuelve el
            // bundleId REAL del proceso que tiene el socket. Sin esto el
            // doctor reportaba "observer disponible" aunque el socket lo
            // tuviera OTRA app (p.ej. tras probar con apps de sistema).
            let observed = observerProbe.observedBundleId()
            if let observed {
                print("  ✓ Observer in-process (socket 7002, app: \(observed)) — iOSAgentBackend prioritario")
            } else {
                print("  ✓ Observer in-process (socket 7002) — iOSAgentBackend prioritario")
            }
            if let expected = AutoPilotConfig.readAll()["bundle"],
               let observed, observed != expected {
                print("  ⚠ El socket 7002 responde desde '\(observed)', NO desde la app configurada ('\(expected)')")
                print("    Remedio: auto launch \(expected)   (la inyección del observer es default)")
            }
            if ProcessInfo.processInfo.environment["AUTO_FORCE_AX"] == "1" {
                print("  ⚠ AUTO_FORCE_AX=1 — AXBackend forzado además del observer (debug)")
            }
        } else {
            // Post-#164 el remedio es RELANZAR (la inyección es default), no
            // recompilar. Mensaje neutro: no distinguimos observer-por-build
            // vs por-inyección sin `nm` del binario (caro) — el relaunch cubre
            // ambos casos en simulator; en device el observer viene del build.
            print("  ○ Observer no disponible — motor: XCUI runner (deep, sin robo de foco)")
            print("    Remedio: relanza la app con `auto launch <bundle>` — inyecta el observer por defecto")
            print("    (apps de sistema no aceptan la inyección; en device físico el observer va linkeado en el build)")
        }
        let daemonStatus = Process()
        daemonStatus.executableURL = URL(fileURLWithPath: "/bin/ls")
        daemonStatus.arguments = ["/tmp"]
        let daemonPipe = Pipe()
        daemonStatus.standardOutput = daemonPipe
        try? daemonStatus.run()
        daemonStatus.waitUntilExit()
        let tmpFiles = String(data: daemonPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if tmpFiles.contains("autopilot-") && tmpFiles.contains(".pid") {
            print("  ✓ Daemon autopilotd corriendo (XCUI deep disponible)")
        } else {
            print("  ○ Daemon autopilotd no corriendo — `tree deep`/`list` lo arrancan on-demand (auto daemon start)")
        }

        print("\nEnvironment:")
        print("  PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(not set)")")
        print("  DEVELOPER_DIR: \(ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "(not set)")")
    }
}
