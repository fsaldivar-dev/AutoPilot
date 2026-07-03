import Foundation

/// En Compose los click handlers viven en `Button`, no en `TextView`. Cuando un
/// match cae sobre un TextView hay que subir al Button contenedor más pequeño.
/// Esto resuelve el issue #59 (Android Compose buttons sin contentDescription).
///
/// Post-#151 el hit-test usa el CENTRO del frame del target (no la esquina
/// superior-izquierda) y los candidatos se restringen a la MISMA ventana que
/// el target: el tree multi-ventana (#130) expone las ventanas no-activas
/// (IME, overlays, diálogos) como nodos sintéticos `role: "Window"` top-level,
/// y un clickable del teclado (Gboard expone FrameLayouts clickables
/// invisibles) NO debe capturar un tap dirigido a un elemento de la app.
public enum AndroidComposeResolver {

    public static func findClickableFrame(for element: [String: Any], in tree: [[String: Any]]) -> [String: Any]? {
        guard let frame = element["frame"] as? [String: Any],
              let ex = frame["x"] as? Int, let ey = frame["y"] as? Int else { return nil }
        // Centro del frame, no la esquina (#151): la esquina puede caer bajo
        // un overlay ajeno, y el centro es donde el tap se inyecta realmente.
        let cx = ex + ((frame["width"] as? Int ?? 0) / 2)
        let cy = ey + ((frame["height"] as? Int ?? 0) / 2)
        let scope = windowScope(of: element, in: tree)
        return findButtonContaining(x: cx, y: cy, in: scope)
    }

    public static func findButtonContaining(x: Int, y: Int, in elements: [[String: Any]]) -> [String: Any]? {
        var bestFrame: [String: Any]?
        var bestArea = Int.max
        findSmallest(x: x, y: y, in: elements, bestFrame: &bestFrame, bestArea: &bestArea)
        return bestFrame
    }

    private static func findSmallest(x: Int, y: Int, in elements: [[String: Any]], bestFrame: inout [String: Any]?, bestArea: inout Int) {
        for element in elements {
            let role = (element["role"] as? String) ?? ""
            let clickable = (element["clickable"] as? Bool) ?? false

            if (role == "Button" || clickable),
               let frame = element["frame"] as? [String: Any],
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let area = fw * fh
                if x >= fx && x <= fx + fw && y >= fy && y <= fy + fh && area < bestArea {
                    bestArea = area
                    bestFrame = frame
                }
            }
            if let children = element["children"] as? [[String: Any]] {
                findSmallest(x: x, y: y, in: children, bestFrame: &bestFrame, bestArea: &bestArea)
            }
        }
    }

    // MARK: - #151: aislamiento por ventana

    /// Subárboles donde es válido buscar el clickable padre del target.
    ///
    /// - Target dentro de una ventana secundaria (nodo sintético `Window`,
    ///   p.ej. una tecla del IME) → solo ese subárbol.
    /// - Target en la ventana activa de la app (o no localizable en el tree)
    ///   → los nodos top-level que NO son ventanas secundarias. Así un
    ///   clickable del IME/overlay jamás es candidato para un target de la app.
    ///
    /// Sin nodos `Window` en el tree (teclado cerrado, agentes pre-#130) el
    /// scope es el tree completo — comportamiento idéntico al anterior.
    static func windowScope(of element: [String: Any], in tree: [[String: Any]]) -> [[String: Any]] {
        let target = element as NSDictionary
        var appNodes: [[String: Any]] = []
        for node in tree {
            if isSecondaryWindow(node) {
                if subtreeContains(node, target) { return [node] }
            } else {
                appNodes.append(node)
            }
        }
        return appNodes
    }

    /// Nodo sintético de ventana no-activa agregado por el agente (#130):
    /// `role: "Window"` con el tipo en `title` (IME, System, Overlay, ...).
    private static func isSecondaryWindow(_ node: [String: Any]) -> Bool {
        (node["role"] as? String) == "Window"
    }

    private static func subtreeContains(_ node: [String: Any], _ target: NSDictionary) -> Bool {
        if (node as NSDictionary).isEqual(target) { return true }
        for child in (node["children"] as? [[String: Any]]) ?? [] {
            if subtreeContains(child, target) { return true }
        }
        return false
    }
}
