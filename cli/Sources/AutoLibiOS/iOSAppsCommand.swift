import Foundation
import AutoCore

// `auto apps` (#187) — lista las apps instaladas del simulador booteado.
// Output parseable (fuente del predictivo de bundleId del editor): una línea
// por app `bundleId<TAB>nombre`. Por default excluye apps de sistema
// (com.apple.*); `--all` las incluye.
public enum iOSAppsCommand {
    public static func execute(args: [String]) throws {
        let includeSystem = args.contains("--all")

        // simctl listapps emite un plist old-style — plutil lo convierte a
        // JSON para no parsear ese formato a mano.
        let listapps = Process()
        let plutil = Process()
        let plistPipe = Pipe()
        let jsonPipe = Pipe()

        listapps.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        listapps.arguments = ["simctl", "listapps", "booted"]
        listapps.standardOutput = plistPipe
        listapps.standardError = FileHandle.nullDevice

        plutil.executableURL = URL(fileURLWithPath: "/usr/bin/plutil")
        plutil.arguments = ["-convert", "json", "-o", "-", "--", "-"]
        plutil.standardInput = plistPipe
        plutil.standardOutput = jsonPipe

        try listapps.run()
        try plutil.run()
        plutil.waitUntilExit()
        listapps.waitUntilExit()

        guard listapps.terminationStatus == 0 else {
            throw BridgeError.noBootedDevice
        }

        let data = jsonPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try? JSONSerialization.jsonObject(with: data)
                as? [String: [String: Any]]
        else {
            throw BridgeError.simctlFailed("apps: no pude parsear simctl listapps")
        }

        var rows: [(bundle: String, name: String)] = []
        for (bundle, info) in json {
            if !includeSystem && bundle.hasPrefix("com.apple.") { continue }
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String)
                ?? bundle
            rows.append((bundle, name))
        }

        for row in rows.sorted(by: { $0.bundle < $1.bundle }) {
            print("\(row.bundle)\t\(row.name)")
        }
        if rows.isEmpty {
            print("(sin apps de usuario — usa `apps --all` para incluir las de sistema)")
        }
    }
}
