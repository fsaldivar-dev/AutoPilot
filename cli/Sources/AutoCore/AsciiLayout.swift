import Foundation
import CoreGraphics

// MARK: - AsciiLayout
//
// Renderer ASCII del layout de la pantalla (#107). Toma el tree serializado
// (mismo formato que TreePrinter: dicts con role/label/title/frame/children)
// y dibuja un "wireframe" en texto: cada elemento visible es una caja
// posicionada proporcionalmente dentro de un grid de caracteres.
//
// Cross-platform por diseño: los roles se normalizan para cubrir iOS AX
// (AXButton, AXStaticText...), iOS XCUI (Button, StaticText...) y Android
// (Button, TextView, EditText, View clickable de Compose...).
//
// Pure Swift, sin dependencias de plataforma — 100% testeable con un tree
// sintético (determinista: mismo input → mismo output).
public enum AsciiLayout {

    // MARK: - Opciones

    public struct Options {
        /// Ancho del grid en caracteres (sin contar el marco exterior).
        public var width: Int = 78
        /// Alto del grid en caracteres (sin contar el marco exterior).
        public var height: Int = 38
        /// Solo elementos con label/title/identifier.
        public var compact: Bool = false
        /// Filtro por tipo ("buttons", "textfields", ... — mismos nombres que `list`).
        public var typeFilter: String? = nil
        /// Zoom: usa el frame del primer elemento cuyo label matchea como viewport.
        public var region: String? = nil

        public init() {}
    }

    /// Tipos aceptados como filtro posicional (`auto layout buttons`).
    /// Alineados con los de `list` para no inventar vocabulario nuevo.
    public static let allowedTypeFilters: Set<String> = [
        "buttons", "labels", "statictexts", "text", "textfields",
        "switches", "checkboxes", "links", "images", "cells",
        "navbars", "navigationbars"
    ]

    // MARK: - Categorías de rol

    /// Categoría visual de un elemento. Cada una tiene su símbolo en el wireframe.
    enum Category: String, CaseIterable {
        case button = "B"
        case text = "T"
        case input = "I"
        case navbar = "N"
        case image = "G"
        case toggle = "S"
        case cell = "C"
        case link = "L"

        var legend: String {
            switch self {
            case .button: return "[B] boton"
            case .text: return "[T] texto"
            case .input: return "[I] input"
            case .navbar: return "[N] navbar"
            case .image: return "[G] imagen"
            case .toggle: return "[S] switch"
            case .cell: return "[C] celda"
            case .link: return "[L] link"
            }
        }
    }

    /// Normaliza un rol de cualquier plataforma a una categoría visual.
    /// Retorna nil para contenedores puros (ScrollView, FrameLayout, Window...).
    static func category(role rawRole: String, clickable: Bool, labeled: Bool) -> Category? {
        // "AXButton" → "button"; "android.widget.EditText" → "edittext"
        var role = rawRole.lowercased()
        if role.hasPrefix("ax") { role = String(role.dropFirst(2)) }
        if let dot = role.lastIndex(of: ".") { role = String(role[role.index(after: dot)...]) }

        switch role {
        case "button", "imagebutton":
            return .button
        case "statictext", "textview", "text":
            return .text
        case "textfield", "securetextfield", "searchfield", "edittext", "textarea":
            return .input
        case "navigationbar", "toolbar", "actionbar", "tabbar", "tabgroup":
            return .navbar
        case "image", "imageview":
            return .image
        case "switch", "checkbox", "togglebutton", "toggle":
            return .toggle
        case "cell", "listitem":
            return .cell
        case "link":
            return .link
        default:
            // Compose expone botones con ícono como View clickable + contentDescription.
            if clickable && labeled { return .button }
            return nil
        }
    }

    /// Mapea el filtro posicional (`buttons`, `textfields`...) a su categoría.
    static func category(forFilter filter: String) -> Category? {
        switch filter.lowercased() {
        case "buttons": return .button
        case "labels", "statictexts", "text": return .text
        case "textfields": return .input
        case "navbars", "navigationbars": return .navbar
        case "images": return .image
        case "switches", "checkboxes": return .toggle
        case "cells": return .cell
        case "links": return .link
        default: return nil
        }
    }

    // MARK: - API

    /// Renderiza el wireframe ASCII. Determinista: mismo tree + viewport +
    /// opciones → mismo string.
    ///
    /// - Parameters:
    ///   - tree: árbol serializado (formato TreePrinter/DeviceBridge.tree()).
    ///   - viewport: bounds de la pantalla en coordenadas del tree.
    ///   - options: grid, filtros, zoom.
    public static func render(tree: [[String: Any]],
                              viewport: CGRect,
                              options: Options = Options()) -> String {
        let tree = pruneSimulatorChrome(tree)
        var vp = viewport

        // --region: zoom al frame del primer elemento que matchea.
        if let region = options.region {
            guard let el = findByLabel(region, in: tree),
                  let frame = ViewportUtil.rect(from: el["frame"] as? [String: Any]) else {
                return "layout: region '\(region)' no encontrada en el tree"
            }
            vp = frame
        }

        guard vp.width > 0, vp.height > 0 else {
            return "layout: viewport invalido (\(Int(vp.width))x\(Int(vp.height)))"
        }

        let items = collectDrawables(tree: tree, viewport: vp, options: options)
        if items.isEmpty {
            return "layout: sin elementos que dibujar (viewport \(Int(vp.width))x\(Int(vp.height)))"
        }

        let gridW = max(20, options.width)
        let gridH = max(10, options.height)
        var grid = [[Character]](repeating: [Character](repeating: " ", count: gridW), count: gridH)

        // Dibujar de mayor a menor área: los chicos pisan a los grandes (z-order
        // aproximado). Empate por orden de documento para determinismo.
        let ordered = items.sorted { a, b in
            let areaA = a.frame.width * a.frame.height
            let areaB = b.frame.width * b.frame.height
            if areaA != areaB { return areaA > areaB }
            return a.order < b.order
        }

        for item in ordered {
            draw(item, into: &grid, viewport: vp, gridW: gridW, gridH: gridH)
        }

        // Componer: marco exterior + grid + leyenda.
        var lines: [String] = []
        lines.append("+" + String(repeating: "-", count: gridW) + "+")
        for row in grid {
            lines.append("|" + String(row) + "|")
        }
        lines.append("+" + String(repeating: "-", count: gridW) + "+")

        let usedCategories = Category.allCases.filter { cat in
            items.contains { $0.category == cat }
        }
        lines.append(usedCategories.map { $0.legend }.joined(separator: "  "))
        lines.append("\(items.count) elemento(s) · viewport \(Int(vp.width))x\(Int(vp.height))")

        return lines.joined(separator: "\n")
    }

    /// Bounding box de los frames raíz del tree — fallback cuando el bridge
    /// no puede resolver viewport (p.ej. en tests o backends parciales).
    public static func boundingBox(of tree: [[String: Any]]) -> CGRect? {
        var box: CGRect?
        for el in tree {
            if let r = ViewportUtil.rect(from: el["frame"] as? [String: Any]) {
                box = box?.union(r) ?? r
            }
        }
        return box
    }

    // MARK: - Chrome del Simulator (#162)

    /// Roles de macOS AX que son chrome de la ventana del Simulator cuando
    /// aparecen como hermanos del contenido del device: controles de la
    /// ventana (close/minimize/zoom), toolbar, título y botones hardware
    /// (Home, Volume...).
    static let windowChromeRoles: Set<String> = [
        "AXButton", "AXToolbar", "AXStaticText", "AXImage",
        "AXMenuButton", "AXPopUpButton", "AXCheckBox", "AXSlider"
    ]

    /// Poda el chrome de la ventana del Simulator de macOS (#162). En el AX
    /// tree, el contenido real del device vive dentro de un AXGroup; sus
    /// hermanos a nivel de ventana (Home/Volume, toolbar, window controls,
    /// título) son chrome del host y no pertenecen al wireframe de la app.
    /// Solo actúa cuando el tree luce como una ventana del Simulator: todos
    /// los roles con prefijo "AX", al menos un AXGroup y al menos un hermano
    /// de chrome. Trees XCUI/observer/Android pasan intactos.
    static func pruneSimulatorChrome(_ tree: [[String: Any]]) -> [[String: Any]] {
        // La raíz puede ser la ventana misma o directamente sus hijos
        // (DeviceBridge.tree() serializa los hijos de la ventana).
        var siblings = tree
        var windowRoot: [String: Any]? = nil
        if tree.count == 1, (tree[0]["role"] as? String) == "AXWindow",
           let children = tree[0]["children"] as? [[String: Any]] {
            siblings = children
            windowRoot = tree[0]
        }

        let roles = siblings.map { ($0["role"] as? String) ?? "" }
        guard roles.allSatisfy({ $0.hasPrefix("AX") }),
              roles.contains("AXGroup"),
              roles.contains(where: { windowChromeRoles.contains($0) }) else {
            return tree
        }

        let content = siblings.filter {
            !windowChromeRoles.contains(($0["role"] as? String) ?? "")
        }
        if var root = windowRoot {
            root["children"] = content
            return [root]
        }
        return content
    }

    // MARK: - Recolección

    struct Drawable {
        let frame: CGRect
        let category: Category
        let label: String
        let order: Int
    }

    private static func collectDrawables(tree: [[String: Any]],
                                         viewport: CGRect,
                                         options: Options) -> [Drawable] {
        let filterCategory = options.typeFilter.flatMap { category(forFilter: $0) }
        var result: [Drawable] = []
        var order = 0

        walk(tree) { el in
            defer { order += 1 }
            guard let frame = ViewportUtil.rect(from: el["frame"] as? [String: Any]) else { return }

            let intersection = frame.intersection(viewport)
            if intersection.isNull || intersection.isEmpty { return }

            // Contenedores gigantes que tapan todo (>90% del viewport) no aportan
            // información espacial — solo ruido encima del resto.
            let vpArea = viewport.width * viewport.height
            if (intersection.width * intersection.height) / vpArea > 0.9 { return }

            let label = bestLabel(of: el)
            let clickable = (el["clickable"] as? Bool) ?? false
            let role = (el["role"] as? String) ?? ""

            guard let cat = category(role: role, clickable: clickable, labeled: !label.isEmpty) else { return }
            if let want = filterCategory, cat != want { return }
            if options.compact && label.isEmpty { return }

            result.append(Drawable(frame: frame, category: cat, label: label, order: order))
        }
        return result
    }

    /// Prioridad de etiqueta: title > label > identifier > value.
    private static func bestLabel(of el: [String: Any]) -> String {
        for key in ["title", "label", "identifier", "value"] {
            if let v = el[key] as? String, !v.isEmpty { return v }
        }
        return ""
    }

    private static func walk(_ nodes: [[String: Any]], visit: ([String: Any]) -> Void) {
        for node in nodes {
            visit(node)
            if let children = node["children"] as? [[String: Any]] {
                walk(children, visit: visit)
            }
        }
    }

    private static func findByLabel(_ query: String, in tree: [[String: Any]]) -> [String: Any]? {
        let needle = query.lowercased()
        var found: [String: Any]?
        walk(tree) { el in
            guard found == nil else { return }
            let haystacks = [
                el["title"] as? String, el["label"] as? String,
                el["identifier"] as? String, el["value"] as? String
            ]
            for h in haystacks {
                if let h, !h.isEmpty, h.lowercased().contains(needle) {
                    found = el
                    return
                }
            }
        }
        return found
    }

    // MARK: - Dibujo

    private static func draw(_ item: Drawable,
                             into grid: inout [[Character]],
                             viewport: CGRect,
                             gridW: Int,
                             gridH: Int) {
        // Escalar bordes del frame al grid, clampeando al área visible.
        func gx(_ x: CGFloat) -> Int {
            let t = (x - viewport.minX) / viewport.width
            return min(gridW - 1, max(0, Int((t * CGFloat(gridW)).rounded(.down))))
        }
        func gy(_ y: CGFloat) -> Int {
            let t = (y - viewport.minY) / viewport.height
            return min(gridH - 1, max(0, Int((t * CGFloat(gridH)).rounded(.down))))
        }

        let x0 = gx(item.frame.minX)
        let x1 = max(x0, gx(item.frame.maxX - 1))
        let y0 = gy(item.frame.minY)
        let y1 = max(y0, gy(item.frame.maxY - 1))
        let boxW = x1 - x0 + 1
        let boxH = y1 - y0 + 1

        let tag = item.label.isEmpty
            ? "[\(item.category.rawValue)]"
            : "[\(item.category.rawValue)] \(item.label)"

        // Cajas con área suficiente: bordes + etiqueta en el interior.
        if boxW >= 4 && boxH >= 3 {
            // Limpiar interior para que el contenido de cajas grandes no se cuele.
            for row in y0...y1 {
                for col in x0...x1 {
                    grid[row][col] = " "
                }
            }
            for col in x0...x1 {
                grid[y0][col] = "-"
                grid[y1][col] = "-"
            }
            for row in y0...y1 {
                grid[row][x0] = "|"
                grid[row][x1] = "|"
            }
            grid[y0][x0] = "+"; grid[y0][x1] = "+"
            grid[y1][x0] = "+"; grid[y1][x1] = "+"

            let inner = boxW - 2
            let text = truncate(tag, to: inner)
            let row = y0 + 1
            for (i, ch) in text.enumerated() {
                grid[row][x0 + 1 + i] = ch
            }
        } else {
            // Elemento chico para caja: solo la etiqueta, truncada al espacio que
            // queda en la fila. Puede desbordar su caja — a esta escala prima la
            // legibilidad; la posición sigue siendo proporcional.
            let text = truncate(tag, to: gridW - x0)
            for (i, ch) in text.enumerated() {
                grid[y0][x0 + i] = ch
            }
        }
    }

    /// Trunca con ".." para que se note el corte (ASCII puro, sin ellipsis unicode).
    private static func truncate(_ s: String, to width: Int) -> String {
        guard width > 0 else { return "" }
        if s.count <= width { return s }
        if width <= 2 { return String(s.prefix(width)) }
        return String(s.prefix(width - 2)) + ".."
    }
}
