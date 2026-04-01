import Foundation
import XCTest

/// Routes incoming JSON commands to the appropriate handler.
/// Supports switching target app dynamically with the "target" command.
final class CommandRouter {

    private var currentApp: XCUIApplication
    private var currentBundleId: String
    private var inspector: ElementInspector
    private var actions: Actions

    init(app: XCUIApplication, bundleId: String = "com.autoapp.runner") {
        self.currentApp = app
        self.currentBundleId = bundleId
        self.inspector = ElementInspector(app: app)
        self.actions = Actions(app: app, inspector: inspector)
    }

    /// Switch the target app that all commands operate on.
    private func switchTarget(bundleId: String) {
        let newApp = XCUIApplication(bundleIdentifier: bundleId)
        newApp.activate()
        currentApp = newApp
        currentBundleId = bundleId
        inspector = ElementInspector(app: newApp)
        actions = Actions(app: newApp, inspector: inspector)
        print("[AutoApp] Target switched to: \(bundleId)")
    }

    /// Processes a raw JSON request and returns a JSON response.
    func handle(data: Data) -> Data {
        let startTime = CFAbsoluteTimeGetCurrent()

        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = request["id"],
                  let cmd = request["cmd"] as? String else {
                return errorResponse(id: 0, error: "Invalid request format")
            }

            let requestId = id
            let args = request["args"] as? [String: Any] ?? [:]

            let result = try route(cmd: cmd, args: args)

            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)

            var response: [String: Any] = [
                "id": requestId,
                "ok": true,
                "time": elapsed
            ]

            for (key, value) in result {
                response[key] = value
            }

            return serialize(response)

        } catch {
            let elapsed = Int((CFAbsoluteTimeGetCurrent() - startTime) * 1000)
            return errorResponse(id: 0, error: "\(error)", time: elapsed)
        }
    }

    // MARK: - Routing

    private func route(cmd: String, args: [String: Any]) throws -> [String: Any] {
        switch cmd {

        // Target management
        case "target":
            let bundleId = try requireString(args, key: "bundleId")
            switchTarget(bundleId: bundleId)
            return ["bundleId": bundleId]

        case "currentTarget":
            return ["bundleId": currentBundleId]

        // Inspection
        case "tree":
            let tree = inspector.tree()
            return ["data": tree]

        case "search":
            let query = args["query"] as? String ?? ""
            let results = inspector.search(query: query)
            return ["data": results]

        case "elementAt":
            guard let x = args["x"] as? Double,
                  let y = args["y"] as? Double else {
                throw RouterError.missingArgs("x, y")
            }
            if let element = inspector.elementAt(x: x, y: y) {
                return ["data": element]
            } else {
                return ["data": NSNull(), "found": false]
            }

        // Actions
        case "tap":
            let target = try requireString(args, key: "target")
            return try actions.tap(target: target)

        case "doubleTap":
            let target = try requireString(args, key: "target")
            return try actions.doubleTap(target: target)

        case "longPress":
            let target = try requireString(args, key: "target")
            let duration = args["duration"] as? Double ?? 1.0
            return try actions.longPress(target: target, duration: duration)

        case "type":
            let text = try requireString(args, key: "text")
            let target = args["target"] as? String
            return try actions.typeText(target: target, text: text)

        case "swipe":
            let direction = try requireString(args, key: "direction")
            let target = args["target"] as? String
            return try actions.swipe(direction: direction, target: target)

        case "screenshot":
            return actions.screenshot()

        case "launch":
            let bundleId = try requireString(args, key: "bundleId")
            let result = actions.launch(bundleId: bundleId)
            // Auto-switch target to the launched app
            switchTarget(bundleId: bundleId)
            return result

        case "terminate":
            let bundleId = try requireString(args, key: "bundleId")
            return actions.terminate(bundleId: bundleId)

        case "waitFor":
            let target = try requireString(args, key: "target")
            let timeout = args["timeout"] as? Double ?? 10.0
            return try actions.waitFor(target: target, timeout: timeout)

        case "exists":
            let target = try requireString(args, key: "target")
            return actions.exists(target: target)

        case "getAttribute":
            let target = try requireString(args, key: "target")
            let attribute = try requireString(args, key: "attribute")
            return try actions.getAttribute(target: target, attribute: attribute)

        case "ping":
            return ["pong": true]

        default:
            throw RouterError.unknownCommand(cmd)
        }
    }

    // MARK: - Helpers

    private func requireString(_ args: [String: Any], key: String) throws -> String {
        guard let value = args[key] as? String else {
            throw RouterError.missingArgs(key)
        }
        return value
    }

    private func serialize(_ dict: [String: Any]) -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        } catch {
            return errorResponse(id: 0, error: "Serialization failed: \(error)")
        }
    }

    private func errorResponse(id: Any = 0, error: String, time: Int = 0) -> Data {
        let dict: [String: Any] = [
            "id": id,
            "ok": false,
            "error": error,
            "time": time
        ]
        return (try? JSONSerialization.data(withJSONObject: dict, options: [])) ?? Data()
    }
}

// MARK: - Errors

enum RouterError: Error, CustomStringConvertible {
    case unknownCommand(String)
    case missingArgs(String)

    var description: String {
        switch self {
        case .unknownCommand(let cmd): return "Unknown command: \(cmd)"
        case .missingArgs(let args): return "Missing required args: \(args)"
        }
    }
}
