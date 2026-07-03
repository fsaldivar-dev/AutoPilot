import Foundation
import CoreGraphics

// MARK: - TreeQuery
//
// Consultas compartidas sobre el árbol serializado `[[String: Any]]` que
// devuelven los bridges. Desde #150 TODOS los backends emiten árbol ANIDADO
// (key "children"): agente Android, observer iOS, XCUI runner, AX macOS y
// uiautomator legacy. Cualquier consumidor que itere el array top-level sin
// recursar sobre children solo ve las ventanas raíz — estos helpers son la
// forma canónica de recorrerlo.
//
// Pure Swift — sin AX ni dependencias de plataforma; testeable en macOS.

public enum TreeQuery {

    /// Visita cada nodo del árbol en pre-order (padre antes que hijos),
    /// recursivo sobre "children".
    public static func walk(_ nodes: [[String: Any]], visit: ([String: Any]) -> Void) {
        for node in nodes {
            visit(node)
            if let children = node["children"] as? [[String: Any]] {
                walk(children, visit: visit)
            }
        }
    }

    /// Todos los nodos del árbol como lista plana (pre-order). Los dicts
    /// conservan su key "children" — los consumidores de listado solo leen
    /// las keys escalares.
    public static func flatten(_ tree: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        walk(tree) { out.append($0) }
        return out
    }

    /// Búsqueda `contains` case-insensitive sobre title / label / identifier /
    /// value / placeholder, recursiva. `value` participa a propósito: en
    /// Android el texto de un campo ES `title`/`value` (node.text), y en iOS
    /// (#166) el texto tipeado vive en `value` y el placeholder en su propia
    /// key — sin ellas `exists`/`waitFor` no verían texto de inputs.
    public static func search(_ tree: [[String: Any]], query: String) -> [[String: Any]] {
        let q = query.lowercased()
        var results: [[String: Any]] = []
        walk(tree) { node in
            for key in ["title", "label", "identifier", "value", "placeholder"] {
                if let s = node[key] as? String, !s.isEmpty, s.lowercased().contains(q) {
                    results.append(node)
                    return
                }
            }
        }
        return results
    }

    /// Nodo MÁS PEQUEÑO cuyo frame contiene (x, y) — el equivalente a hitTest
    /// sobre el árbol serializado: el nodo concreto, no el contenedor que
    /// también contiene el punto. Acepta frames con valores Int o Double
    /// (los backends serializan distinto — ver ViewportUtil.rect).
    public static func deepestNode(x: Double, y: Double, in tree: [[String: Any]]) -> [String: Any]? {
        var best: [String: Any]?
        var bestArea = CGFloat.greatestFiniteMagnitude
        let point = CGPoint(x: x, y: y)
        walk(tree) { node in
            guard let rect = ViewportUtil.rect(from: node["frame"] as? [String: Any]),
                  rect.contains(point) else { return }
            let area = rect.width * rect.height
            if area < bestArea {
                bestArea = area
                best = node
            }
        }
        return best
    }
}
