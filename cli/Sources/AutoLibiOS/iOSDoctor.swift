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
            let deviceId = try bridge.getBootedDeviceId()
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

        print("\nAccessibility Permission:")
        if AXIsProcessTrusted() {
            print("  ✓ Granted")
        } else {
            print("  ✗ Not granted — add this app to: System Settings > Privacy & Security > Accessibility")
        }

        // ARD-002 Phase 5 (#116): reportar qué backend está activo
        print("\nBackend activo:")
        let observerLive = iOSAgentBridge().probeSocket()
        if observerLive {
            print("  ✓ Observer in-process (socket 7002) — iOSAgentBackend prioritario")
            if ProcessInfo.processInfo.environment["AUTO_FORCE_AX"] == "1" {
                print("  ⚠ AUTO_FORCE_AX=1 — AXBackend forzado además del observer (debug)")
            }
        } else {
            print("  ○ Observer no disponible — fallback AX macOS + XCUI runner")
            print("    (para usar el observer: compilar la app con `auto build` — ver docs/ios/OBSERVER-MIGRATION.md)")
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
