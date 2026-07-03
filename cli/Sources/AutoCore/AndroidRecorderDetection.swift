import Foundation

/// Lógica pura de detección sobre el tree Android para el recorder.
/// Post-#130 el agente expone las ventanas no-activas (IME, overlays,
/// diálogos del sistema) como nodos sintéticos `role: "Window"` con el
/// tipo en `title` ("IME", "System", "Application", ...), el `package`
/// del root de la ventana y su `frame` en pantalla. Eso habilita:
///
/// - **#54**: clasificar un touch como tecleo si cae dentro del frame de la
///   ventana IME, y reconstruir el texto tecleado con un diff del `value`
///   del campo editable enfocado (antes de abrir el teclado vs al cerrarlo).
/// - **#53**: detectar que el touch cayó en un diálogo de permisos del
///   sistema (package del permissioncontroller) y emitir
///   `permission grant <service> <package>` en vez de un tap frágil.
///
/// Todo es estático y puro (tree como `[[String: Any]]`) para poder
/// testearlo con trees mock sin emulador.
public enum AndroidRecorderDetection {

    // MARK: - #54: ventana IME

    /// Frame de la ventana IME (teclado virtual) si está visible en el tree.
    /// Los nodos Window son top-level (el agente los agrega junto al root
    /// de la ventana activa), pero se busca recursivo por robustez.
    public static func imeFrame(in tree: [[String: Any]]) -> CGRect? {
        for node in tree {
            if isIMEWindow(node), let frame = frameRect(of: node) {
                return frame
            }
            if let children = node["children"] as? [[String: Any]],
               let frame = imeFrame(in: children) {
                return frame
            }
        }
        return nil
    }

    /// ¿El punto cae dentro de la ventana del teclado virtual?
    public static func isPointInsideIME(x: Int, y: Int, tree: [[String: Any]]) -> Bool {
        guard let frame = imeFrame(in: tree) else { return false }
        return frame.contains(CGPoint(x: CGFloat(x), y: CGFloat(y)))
    }

    private static func isIMEWindow(_ node: [String: Any]) -> Bool {
        (node["role"] as? String) == "Window" && (node["title"] as? String) == "IME"
    }

    // MARK: - #54: value del campo enfocado

    /// Value del campo editable enfocado, buscando SOLO fuera de la ventana
    /// IME (algunos teclados tienen campos internos enfocables, y la strip
    /// de sugerencias no debe contar como "lo que el usuario escribió").
    public static func focusedEditableValue(in tree: [[String: Any]]) -> String? {
        for node in tree {
            if isIMEWindow(node) { continue }
            if let value = findFocusedEditable(in: node) { return value }
        }
        return nil
    }

    private static func findFocusedEditable(in node: [String: Any]) -> String? {
        let role = (node["role"] as? String ?? "").lowercased()
        let focused = node["focused"] as? Bool ?? false
        if focused && isEditableRole(role) {
            // El agente serializa node.text en "value" y "title" por igual
            if let value = node["value"] as? String { return value }
            return node["title"] as? String ?? ""
        }
        for child in (node["children"] as? [[String: Any]]) ?? [] {
            if let value = findFocusedEditable(in: child) { return value }
        }
        return nil
    }

    /// EditText y derivados (TextInputEditText, AutoCompleteTextView, SearchView).
    static func isEditableRole(_ lowercasedRole: String) -> Bool {
        lowercasedRole.contains("edittext")
            || lowercasedRole.contains("autocomplete")
            || lowercasedRole == "searchview"
    }

    // MARK: - #54: diff de tecleo → comandos .auto

    /// Comandos .auto que reproducen el cambio de value `before` → `after`.
    /// El diff absorbe backspaces y autocorrect: solo importa el estado final.
    /// - `after` con solo sufijo nuevo → `type "<sufijo>"`
    /// - `after` es prefijo de `before` → `eraseText N`
    /// - edición mixta → `eraseText <before.count>` + `type "<after>"`
    /// - campo password (value enmascarado ••••) → comment de advertencia
    public static func typingCommands(before: String?, after: String?) -> [String] {
        let b = before ?? ""
        let a = after ?? ""
        guard a != b else { return [] }

        var commands: [String] = []
        if b.isEmpty {
            commands.append("type \(quoted(a))")
        } else if a.hasPrefix(b) {
            commands.append("type \(quoted(String(a.dropFirst(b.count))))")
        } else if b.hasPrefix(a) {
            commands.append("eraseText \(b.count - a.count)")
        } else {
            commands.append("eraseText \(b.count)")
            if !a.isEmpty { commands.append("type \(quoted(a))") }
        }

        if isMaskedValue(a) {
            commands.insert("# campo password — el tree enmascara el texto; reemplaza el type con el valor real", at: 0)
        }
        return commands
    }

    /// ¿Value enmascarado de un campo password? (solo bullets/asteriscos)
    public static func isMaskedValue(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.allSatisfy { "•●·*".contains($0) }
    }

    /// Quotea texto para una línea .auto. El tokenizer no soporta escapes,
    /// pero sí comillas simples: si el texto trae `"`, se envuelve en `'`.
    /// Si trae ambas, se degradan las dobles a simples (best effort).
    static func quoted(_ text: String) -> String {
        if !text.contains("\"") { return "\"\(text)\"" }
        if !text.contains("'") { return "'\(text)'" }
        return "\"\(text.replacingOccurrences(of: "\"", with: "'"))\""
    }

    // MARK: - #54: tecla Enter dentro del IME

    /// Si el toque dentro del IME cayó sobre una tecla Enter/Done/Search
    /// expuesta por accesibilidad, devuelve true (→ emitir `pressKey enter`).
    /// GBoard no siempre expone teclas individuales al tree; en ese caso
    /// devuelve false y el toque se absorbe como tecleo normal (fail-safe:
    /// el diff de value sigue siendo correcto).
    public static func isEnterKeyTap(x: Int, y: Int, tree: [[String: Any]]) -> Bool {
        guard let label = imeKeyLabel(x: x, y: y, tree: tree) else { return false }
        let lower = label.lowercased()
        let enterLabels = ["enter", "intro", "return", "done", "listo", "hecho",
                           "search", "buscar", "go", "ir", "next", "siguiente", "send", "enviar"]
        return enterLabels.contains(lower)
    }

    /// Label (contentDescription/text) del nodo más profundo del subárbol IME
    /// que contiene el punto. nil si el teclado no expone teclas al tree.
    public static func imeKeyLabel(x: Int, y: Int, tree: [[String: Any]]) -> String? {
        for node in tree {
            guard isIMEWindow(node),
                  let children = node["children"] as? [[String: Any]] else { continue }
            return deepestLabel(x: x, y: y, in: children)
        }
        return nil
    }

    private static func deepestLabel(x: Int, y: Int, in nodes: [[String: Any]]) -> String? {
        var best: String?
        var bestArea = Int.max
        func walk(_ nodes: [[String: Any]]) {
            for node in nodes {
                if let frame = frameRect(of: node),
                   frame.contains(CGPoint(x: CGFloat(x), y: CGFloat(y))) {
                    let area = Int(frame.width * frame.height)
                    let label = firstNonEmpty(node["label"] as? String, node["title"] as? String)
                    if let label, area < bestArea, area > 0 {
                        bestArea = area
                        best = label
                    }
                }
                if let children = node["children"] as? [[String: Any]] {
                    walk(children)
                }
            }
        }
        walk(nodes)
        return best
    }

    // MARK: - Helpers compartidos

    static func frameRect(of node: [String: Any]) -> CGRect? {
        guard let frame = node["frame"] as? [String: Any],
              let x = frame["x"] as? Int, let y = frame["y"] as? Int,
              let w = frame["width"] as? Int, let h = frame["height"] as? Int else {
            return nil
        }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

}
