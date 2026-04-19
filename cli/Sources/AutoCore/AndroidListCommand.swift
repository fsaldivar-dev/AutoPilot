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
        "all", "buttons", "labels", "statictexts", "text", "textfields",
        "cells", "switches", "checkboxes", "links", "images",
        "navbars", "navigationbars"
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
        // Pre-computar índice de nodos con label para poder hacer lookup por frame overlap
        let labeledNodes = collectLabeledNodes(tree)
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
            var displayLabel = label.isEmpty ? title : label

            // Si es un Button sin label (típico de FABs en Compose donde el
            // contentDescription vive en un sibling View con el mismo frame) →
            // heredar del nodo labeleado más pequeño que esté dentro del frame.
            var derivedFrom = ""
            if displayLabel.isEmpty {
                if let inherited = findLabelWithinFrame(of: item, in: labeledNodes) {
                    displayLabel = inherited
                    derivedFrom = " (derived)"
                }
            }

            let frame: String = {
                guard let f = item["frame"] as? [String: Any] else { return "" }
                return "[\(f["x"] ?? 0),\(f["y"] ?? 0) \(f["width"] ?? 0)x\(f["height"] ?? 0)]"
            }()

            var line = role
            if !displayLabel.isEmpty { line += "  label=\"\(displayLabel)\"\(derivedFrom)" }
            if !ident.isEmpty { line += "  id=\(ident)" }
            if !value.isEmpty && value != displayLabel { line += "  value=\"\(value)\"" }
            line += "  \(frame)"
            print(line)
        }
        return true
    }

    /// Recolecta todos los nodos con label no vacío + su frame.
    /// Usado como índice para derivar labels por superposición geométrica.
    private static func collectLabeledNodes(_ nodes: [[String: Any]]) -> [(label: String, frame: CGRect)] {
        var out: [(label: String, frame: CGRect)] = []
        walk(nodes) { node in
            let label = (node["label"] as? String) ?? (node["title"] as? String) ?? ""
            guard !label.isEmpty else { return }
            guard let f = node["frame"] as? [String: Any],
                  let x = f["x"] as? Int, let y = f["y"] as? Int,
                  let w = f["width"] as? Int, let h = f["height"] as? Int,
                  w > 0, h > 0 else { return }
            out.append((label: label, frame: CGRect(x: x, y: y, width: w, height: h)))
        }
        return out
    }

    /// Busca el label más pequeño cuyo frame esté contenido dentro del frame del nodo.
    /// Estrategia: en Compose, el contentDescription suele vivir en un sibling
    /// `View` ligeramente más pequeño que el Button. Elegimos el match más chico
    /// para evitar heredar labels de ancestros o elementos externos.
    private static func findLabelWithinFrame(of node: [String: Any], in labeledNodes: [(label: String, frame: CGRect)]) -> String? {
        guard let f = node["frame"] as? [String: Any],
              let x = f["x"] as? Int, let y = f["y"] as? Int,
              let w = f["width"] as? Int, let h = f["height"] as? Int,
              w > 0, h > 0 else { return nil }
        let parent = CGRect(x: x, y: y, width: w, height: h)

        let candidates = labeledNodes
            .filter { parent.contains($0.frame) && $0.frame != parent }
            .sorted { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        return candidates.first?.label
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
        let label = (node["label"] as? String) ?? ""
        let hasContent = !label.isEmpty || !(node["title"] as? String ?? "").isEmpty

        // Roles de layout puros que nunca queremos en ningún listado excepto `all`
        let layoutRoles: Set<String> = ["framelayout", "linearlayout", "composeview", "view"]

        switch type {
        case "all":
            // Todo lo que no sea layout container puro sin contenido
            return !layoutRoles.contains(role) || hasContent || clickable
        case "buttons":
            // Button real O clickable con label (Compose suele usar View clickable
            // con contentDescription para botones con ícono)
            return role == "button" || role == "imagebutton" ||
                   (clickable && hasContent)
        case "labels", "statictexts", "text":
            return role == "textview" || role == "statictext"
        case "textfields":
            return role == "edittext" || role == "textfield"
        case "switches", "checkboxes":
            return role == "switch" || role == "checkbox" || role == "togglebutton"
        case "links":
            return role == "link"
        case "images":
            // Android/Compose no expone ImageView por rol en UiAutomator — están
            // bajo View/ComposeView. Heurística: nodos con label/contentDesc que
            // no son clickable (los clickables ya son buttons) y no tienen otro rol.
            return role == "imageview" || role == "image" ||
                   (role == "view" && hasContent && !clickable)
        case "cells":
            return role == "cell" || role == "listitem" || role == "recyclerview"
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
