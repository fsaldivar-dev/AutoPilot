import Foundation

/// Diagnóstico del entorno Android: ANDROID_HOME, adb, dispositivos, agent socket, DNS.
public enum AndroidDoctor {

    public static func run(bridge: any DeviceBridge, useLegacy: Bool) {
        print("AutoPilot Doctor — Android Environment Check\n")

        let env = ProcessInfo.processInfo.environment

        print("ANDROID_HOME:")
        if let home = env["ANDROID_HOME"] {
            print("  ✓ \(home)")
        } else if let root = env["ANDROID_SDK_ROOT"] {
            print("  ~ ANDROID_SDK_ROOT=\(root) (legacy, prefer ANDROID_HOME)")
        } else {
            print("  ✗ Not set — IDEs may not inherit shell env vars")
        }

        print("\nadb:")
        do {
            let legacy = bridge as? AdbLegacyBridge ?? AdbLegacyBridge()
            let devices = try legacy.listDevices()
            let adbVer = Process()
            adbVer.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            adbVer.arguments = ["adb", "version"]
            let adbPipe = Pipe()
            adbVer.standardOutput = adbPipe
            adbVer.standardError = Pipe()
            adbVer.environment = env
            try? adbVer.run()
            adbVer.waitUntilExit()
            let verOut = (String(data: adbPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = verOut.components(separatedBy: .newlines).first ?? "found"
            print("  ✓ \(firstLine)")

            print("\nDevices:")
            if devices.isEmpty {
                print("  ✗ No devices connected — run an emulator or connect a device")
            } else {
                for device in devices {
                    let name = (device["name"] as? String) ?? "unknown"
                    let udid = (device["udid"] as? String) ?? "?"
                    let state = (device["state"] as? String) ?? "?"
                    let icon = state == "Booted" ? "✓" : "~"
                    print("  \(icon) \(name) (\(udid)) — \(state)")
                }
            }
        } catch {
            print("  ✗ Not found — \(error)")
            print("  Checked: ANDROID_HOME, ANDROID_SDK_ROOT, ~/Library/Android/sdk, /opt/homebrew, PATH")
        }

        print("\nAgent Socket:")
        if let agent = bridge as? AgentBridge {
            do {
                _ = try agent.search(query: "__doctor_probe__")
                print("  ✓ Connected")
            } catch {
                print("  ✗ Not connected — ensure agent is running:")
                print("    adb forward tcp:9008 localabstract:autopilot")
                print("    adb shell am instrument -w dev.autopilot.agent/.AgentInstrumentation")
            }
        } else {
            print("  ~ Using legacy bridge (--legacy), agent not required")
        }

        print("\nEmulator DNS:")
        do {
            let legacy = bridge as? AdbLegacyBridge ?? AdbLegacyBridge()
            let devs = try legacy.listDevices()
            let booted = devs.first(where: { ($0["state"] as? String) == "Booted" })
            if let udid = booted?["udid"] as? String {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                proc.arguments = ["adb", "-s", udid, "shell", "ping", "-c", "1", "-W", "2", "google.com"]
                let out = Pipe(); proc.standardOutput = out; proc.standardError = Pipe()
                proc.environment = env
                try? proc.run()
                proc.waitUntilExit()
                let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus == 0 && output.contains("bytes from") {
                    print("  ✓ google.com resolves from inside the emulator")
                } else {
                    print("  ✗ google.com does NOT resolve — emulator DNS is stale")
                    print("    Cause: netsimd cached an unreachable nameserver (common after WiFi change).")
                    print("    Fix:   cold-boot the emulator with an explicit DNS server")
                    print("           adb -s \(udid) emu kill")
                    print("           emulator -avd <name> -dns-server 8.8.8.8,1.1.1.1 -no-snapshot-load")
                }
            } else {
                print("  ~ No booted device — skipped")
            }
        } catch {
            print("  ~ Skipped — \(error)")
        }

        print("\nEnvironment:")
        print("  PATH: \(env["PATH"] ?? "(not set)")")
        print("  Bridge: \(useLegacy ? "AdbLegacyBridge (--legacy)" : "AgentBridge (default)")")
    }
}
