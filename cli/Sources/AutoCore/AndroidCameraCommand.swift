import Foundation

/// Sub-comando `auto-android camera <start|feed|stop>`. Requiere AgentBridge (JVMTI).
public enum AndroidCameraCommand {

    public static func execute(args: [String], bridge: any DeviceBridge, start: CFAbsoluteTime) throws {
        guard args.count >= 2 else {
            print("Usage: auto-android camera <start|feed|stop> [image] [--package <pkg>]")
            return
        }
        guard let agent = bridge as? AgentBridge else {
            print("Error: camera mock requires agent bridge (not --legacy)")
            return
        }

        let pkgFlag: String? = {
            if let idx = args.firstIndex(of: "--package"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }()
        let config = AutoPilotConfig.readAll()
        guard let package = pkgFlag ?? config["bundle"] else {
            print("Error: no package specified. Use --package <pkg> or set: auto-android config bundle <pkg>")
            return
        }

        let cameraArgs = args.filter { $0 != "--package" && $0 != package }

        switch cameraArgs.count >= 2 ? cameraArgs[1] : "" {
        case "start":
            guard cameraArgs.count >= 3 else {
                print("Usage: auto-android camera start <image.jpg> [--package <pkg>]")
                return
            }
            try agent.cameraStart(imagePath: cameraArgs[2], package: package)
            print("Camera mock injected into \(package) with '\(cameraArgs[2])' (\(elapsedMs(start))ms)")
        case "feed":
            guard cameraArgs.count >= 3 else {
                print("Usage: auto-android camera feed <image.jpg> [--package <pkg>]")
                return
            }
            try agent.cameraFeed(imagePath: cameraArgs[2], package: package)
            print("Camera feed updated: '\(cameraArgs[2])' (\(elapsedMs(start))ms)")
        case "stop":
            try agent.cameraStop(package: package)
            print("Camera stopped for \(package) (\(elapsedMs(start))ms)")
        default:
            print("Unknown camera action: \(args[1]). Use start/feed/stop")
        }
    }
}
