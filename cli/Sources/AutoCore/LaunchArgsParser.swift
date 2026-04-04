import Foundation

/// Parsed result of a `launch` command with optional flags.
public struct LaunchArgs {
    public let bundleId: String
    public let injectImage: String?
    public let envVars: [String: String]

    public init(bundleId: String, injectImage: String? = nil, envVars: [String: String] = [:]) {
        self.bundleId = bundleId
        self.injectImage = injectImage
        self.envVars = envVars
    }
}

/// Parses `launch <bundleId> [--inject image.jpg] [--env KEY=VALUE ...]` arguments.
/// Returns nil if bundleId cannot be determined.
public func parseLaunchArgs(_ args: [String], config: [String: String] = [:]) -> LaunchArgs? {
    // args[0] is "launch"
    guard args.count >= 1 else { return nil }

    // Determine bundleId: first non-flag argument after "launch", or config["bundle"]
    let bundleId: String
    if args.count >= 2 && !args[1].hasPrefix("--") {
        bundleId = args[1]
    } else if let b = config["bundle"] {
        bundleId = b
    } else {
        return nil
    }

    var envVars: [String: String] = [:]
    var injectImage: String? = nil

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
        } else {
            i += 1
        }
    }

    return LaunchArgs(bundleId: bundleId, injectImage: injectImage, envVars: envVars)
}
