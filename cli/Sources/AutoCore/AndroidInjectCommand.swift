import Foundation

/// `auto-android inject <image.jpg>` — hot-swap de la imagen del camera mock
/// sin relanzar la app. Paridad con `auto inject` de iOS.
///
/// Requiere AgentBridge (JVMTI) activo — no funciona con `--legacy`.
public enum AndroidInjectCommand {

    public static func execute(args: [String], bridge: any DeviceBridge, start: CFAbsoluteTime) throws {
        guard args.count >= 2 else {
            print("Usage: auto-android inject <image.jpg> [--package <pkg>]")
            print("Changes the mock camera image without restarting the app.")
            return
        }
        guard let agent = bridge as? AgentBridge else {
            print("Error: inject requires agent bridge (not --legacy)")
            return
        }

        let config = AutoPilotConfig.readAll()
        let pkgFlag: String? = {
            if let idx = args.firstIndex(of: "--package"), idx + 1 < args.count {
                return args[idx + 1]
            }
            return nil
        }()
        guard let package = pkgFlag ?? config["bundle"] else {
            print("Error: no package specified. Use --package <pkg> or set: auto-android config bundle <pkg>")
            return
        }

        var imgPath = args[1]
        if !imgPath.hasPrefix("/") {
            imgPath = FileManager.default.currentDirectoryPath + "/" + imgPath
        }

        try agent.cameraFeed(imagePath: imgPath, package: package)
        print("Camera image updated in \(package) → \(imgPath) (\(elapsedMs(start))ms)")
    }
}
