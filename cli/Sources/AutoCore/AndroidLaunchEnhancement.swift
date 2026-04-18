import Foundation

/// Launch Android con integración al camera mock del AgentBridge (JVMTI).
public enum AndroidLaunchEnhancement {

    public static func execute(args: [String], bridge: any DeviceBridge, start: CFAbsoluteTime) throws {
        let config = AutoPilotConfig.readAll()
        guard let parsed = parseLaunchArgs(args, config: config) else {
            print("Usage: auto-android launch <package> [--inject image.jpg]")
            print("   or: auto-android config bundle dev.autopilot.test.Explorea")
            print("       auto-android launch")
            return
        }

        if let injectImg = parsed.injectImage {
            guard let agent = bridge as? AgentBridge else {
                print("Error: --inject requires agent bridge (not --legacy)")
                return
            }
            var imgPath = injectImg
            if !imgPath.hasPrefix("/") {
                imgPath = FileManager.default.currentDirectoryPath + "/" + imgPath
            }
            try agent.injectAndLaunch(bundleId: parsed.bundleId, imagePath: imgPath)
            let ms = elapsedMs(start)
            print("Launched \(parsed.bundleId) with camera mock → \(imgPath) (\(ms)ms)")
        } else {
            try bridge.launchApp(bundleId: parsed.bundleId, envVars: [:])
            let ms = elapsedMs(start)
            print("Launched \(parsed.bundleId) (\(ms)ms)")
        }
    }
}
