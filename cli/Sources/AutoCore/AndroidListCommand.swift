import Foundation

/// `auto-android list <type>` — listado tipado de elementos (buttons, textfields, etc).
/// Paridad con `auto list <type>` de iOS.
///
/// iOS usa el runner XCUI para typed queries. Android no tiene runner — en su
/// lugar, filtramos el `bridge.tree()` por role del nodo. El agente ya mapea
/// las clases de UiAutomator a roles normalizados (Button, EditText, TextView,
/// Switch, ImageView, etc).
public enum AndroidListCommand {

    public static let allowedTypes: Set<String> = [
        "all", "buttons", "labels", "statictexts", "textfields",
        "cells", "switches", "links", "images", "navbars", "navigationbars"
    ]

    /// Retorna true si manejó el caso; false si el tipo no aplica (fall-through al dispatcher).
    /// Pasa por el `ActionRouter` — respeta el paradigma Command + Capability Discovery.
    public static func execute(args: [String], router: ActionRouter, start: CFAbsoluteTime) async throws -> Bool {
        guard args.count >= 2 else { return false }
        let listType = args[1].lowercased()
        guard allowedTypes.contains(listType) else { return false }

        // Action.tree → router → AgentBackend (o AdbBackend en --legacy)
        let result = try await router.execute(.tree)
        guard case .elements(let tree) = result else {
            print("No elements (tree returned non-elements result)")
            return true
        }
        let items = filter(tree: tree, type: listType)
        let ms = elapsedMs(start)

        if items.isEmpty {
            print("No elements found for type '\(listType)' (\(ms)ms)")
            return true
        }

        print("Found \(items.count) element(s) of type '\(listType)' (\(ms)ms):\n")
        for item in items {
            let role = (item["role"] as? String) ?? "?"
            let label = (item["label"] as? String) ?? ""
            let title = (item["title"] as? String) ?? ""
            let ident = (item["identifier"] as? String) ?? ""
            let value = (item["value"] as? String) ?? ""
            let displayLabel = label.isEmpty ? title : label
            let frame: String = {
                guard let f = item["frame"] as? [String: Any] else { return "" }
                return "[\(f["x"] ?? 0),\(f["y"] ?? 0) \(f["width"] ?? 0)x\(f["height"] ?? 0)]"
            }()

            var line = role
            if !displayLabel.isEmpty { line += "  label=\"\(displayLabel)\"" }
            if !ident.isEmpty { line += "  id=\(ident)" }
            if !value.isEmpty && value != displayLabel { line += "  value=\"\(value)\"" }
            line += "  \(frame)"
            print(line)
        }
        return true
    }

    // MARK: - Filtering

    private static func filter(tree: [[String: Any]], type: String) -> [[String: Any]] {
        var results: [[String: Any]] = []
        walk(tree) { node in
            if matches(node, type: type) {
                results.append(node)
            }
        }
        return results
    }

    private static func matches(_ node: [String: Any], type: String) -> Bool {
        let role = (node["role"] as? String)?.lowercased() ?? ""
        let clickable = (node["clickable"] as? Bool) ?? false

        switch type {
        case "all":
            return role != "group" && role != "container"
        case "buttons":
            return role == "button" || role == "imagebutton" || clickable
        case "labels", "statictexts":
            return role == "textview" || role == "statictext"
        case "textfields":
            return role == "edittext" || role == "textfield"
        case "switches":
            return role == "switch" || role == "checkbox"
        case "links":
            return role == "link"
        case "images":
            return role == "imageview" || role == "image"
        case "cells":
            return role == "cell" || role == "listitem"
        case "navbars", "navigationbars":
            return role == "toolbar" || role == "actionbar" || role == "navigationbar"
        default:
            return false
        }
    }

    private static func walk(_ nodes: [[String: Any]], visit: ([String: Any]) -> Void) {
        for node in nodes {
            visit(node)
            if let children = node["children"] as? [[String: Any]] {
                walk(children, visit: visit)
            }
        }
    }
}
