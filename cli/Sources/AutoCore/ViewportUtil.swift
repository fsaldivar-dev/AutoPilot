import Foundation
import CoreGraphics

// MARK: - ViewportUtil
//
// Geometría compartida para decidir si un frame está "visible" dentro de un
// viewport. Usado por `scrollTo` (y el recorder) en todos los bridges para
// resolver el bug P0 donde `scrollTo` consideraba "found" cualquier match
// del AX tree, aunque estuviera offscreen.
//
// Pure Swift — sin dependencias de AX ni plataforma. Reusable desde iOS fast,
// iOS deep (XCUI runner), Android agent y Android legacy.

public enum ViewportUtil {

    // MARK: - Rect extraction

    /// Extrae un CGRect de un dict {x, y, width, height} (Int | Double).
    /// Los bridges serializan frames con distintos tipos numéricos; normalizamos.
    public static func rect(from frame: [String: Any]?) -> CGRect? {
        guard let frame else { return nil }
        func d(_ key: String) -> Double? {
            if let v = frame[key] as? Double { return v }
            if let v = frame[key] as? Int { return Double(v) }
            if let v = frame[key] as? CGFloat { return Double(v) }
            return nil
        }
        guard let x = d("x"), let y = d("y"),
              let w = d("width"), let h = d("height") else { return nil }
        if w <= 0 || h <= 0 { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Visibility

    /// true si `frame` intersecta con `viewport` cubriendo al menos `minCoverage`
    /// de su área. Intersección mínima evita falsos positivos con elementos que
    /// asoman 1px por el borde (típico en el AX tree con listas virtualizadas).
    ///
    /// - Parameters:
    ///   - frame: frame del elemento (screen coordinates)
    ///   - viewport: bounds del viewport (screen coordinates)
    ///   - minCoverage: fracción del área del frame que debe estar dentro (0.5 = 50%)
    public static func isVisible(frame: CGRect,
                                 inViewport viewport: CGRect,
                                 minCoverage: CGFloat = 0.5) -> Bool {
        let intersection = frame.intersection(viewport)
        if intersection.isNull || intersection.isEmpty { return false }
        let frameArea = frame.width * frame.height
        guard frameArea > 0 else { return false }
        let coverage = (intersection.width * intersection.height) / frameArea
        return coverage >= minCoverage
    }

    // MARK: - Viewport resolution (hybrid)

    /// Dado un tree serializado, busca el ancestro scrolleable del elemento
    /// con el `frame` dado. Si lo encuentra, devuelve su frame. Si no,
    /// devuelve nil.
    ///
    /// Ancestro scrolleable: nodo cuyo `role` contiene "scroll" (AXScrollArea,
    /// ScrollView, androidx.recyclerview.widget.RecyclerView). Se devuelve el
    /// ancestro más cercano al target (el scroll container inmediato).
    public static func scrollableAncestor(of targetFrame: CGRect,
                                          in tree: [[String: Any]]) -> CGRect? {
        var found: CGRect?
        _ = findScrollableAncestor(in: tree,
                                   targetFrame: targetFrame,
                                   currentScrollable: nil,
                                   found: &found)
        return found
    }

    /// Recorre DFS hasta encontrar el target; el scroll container más cercano
    /// (el último `scrollable` acumulado en el path desde root al target) se
    /// escribe en `found`. Retorna true cuando el target fue localizado, para
    /// que los callers puedan early-exit de la recursión.
    @discardableResult
    private static func findScrollableAncestor(in elements: [[String: Any]],
                                               targetFrame: CGRect,
                                               currentScrollable: CGRect?,
                                               found: inout CGRect?) -> Bool {
        for el in elements {
            let role = (el["role"] as? String ?? "").lowercased()
            let elRect = rect(from: el["frame"] as? [String: Any])

            let scrollableHere: CGRect? = {
                if let r = elRect, isScrollableRole(role) { return r }
                return currentScrollable
            }()

            if let elRect = elRect, framesApproxEqual(elRect, targetFrame) {
                found = scrollableHere
                return true
            }

            if let children = el["children"] as? [[String: Any]] {
                if findScrollableAncestor(in: children,
                                          targetFrame: targetFrame,
                                          currentScrollable: scrollableHere,
                                          found: &found) {
                    return true
                }
            }
        }
        return false
    }

    private static func isScrollableRole(_ role: String) -> Bool {
        return role.contains("scroll") ||
               role.contains("recyclerview") ||
               role.contains("listview") ||
               role == "table"
    }

    private static func framesApproxEqual(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 1.0) -> Bool {
        return abs(a.origin.x - b.origin.x) <= tolerance &&
               abs(a.origin.y - b.origin.y) <= tolerance &&
               abs(a.size.width - b.size.width) <= tolerance &&
               abs(a.size.height - b.size.height) <= tolerance
    }

    /// Resuelve viewport híbrido: ancestro scrolleable si existe, sino screenBounds.
    public static func resolveViewport(for element: [String: Any],
                                       in tree: [[String: Any]],
                                       screenBounds: CGRect) -> CGRect {
        guard let frame = rect(from: element["frame"] as? [String: Any]) else {
            return screenBounds
        }
        if let scrollable = scrollableAncestor(of: frame, in: tree) {
            // Intersectamos con screenBounds por si el scrollable se extiende
            // más allá de la pantalla (raro pero posible).
            let clipped = scrollable.intersection(screenBounds)
            return clipped.isNull ? scrollable : clipped
        }
        return screenBounds
    }

    // MARK: - First-match helper

    /// Conveniencia: busca el primer match del target en el tree (usa
    /// TargetResolverShared internamente). Retorna el dict del elemento
    /// si lo encuentra, con su frame ya dentro de `element["frame"]`.
    public static func findFirst(in tree: [[String: Any]],
                                 matching target: String) -> [String: Any]? {
        let parsed = TargetResolverShared.parse(target)
        let all = TargetResolverShared.findAll(in: tree, matching: parsed.label)
        if let idx = parsed.index {
            // 1-based occurrence
            return all.first(where: { $0.occurrence == idx })?.element
        }
        return all.first?.element
    }
}
