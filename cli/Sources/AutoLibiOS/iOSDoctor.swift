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

        print("\nEnvironment:")
        print("  PATH: \(ProcessInfo.processInfo.environment["PATH"] ?? "(not set)")")
        print("  DEVELOPER_DIR: \(ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "(not set)")")
    }
}
