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

    // MARK: - Useful viewport (issue #153)

    /// Fracción vertical del viewport considerada "útil" (banda central).
    /// 0.9 = descarta el 5% superior y el 5% inferior, donde nav bars y tab
    /// bars ocluyen contenido scrolleable (en iOS el tab bar estándar mide
    /// ~83pt de 874 ≈ 9.5% inferior).
    public static let defaultSafeFraction: CGFloat = 0.9

    /// Viewport ÚTIL: la franja del viewport donde un elemento es realmente
    /// visible y tappable. Recorta la banda superior/inferior (franja de
    /// seguridad `safeFraction`) y, además, cualquier barra ocluyente
    /// detectada en el tree (`occlusions`, ver `occludingBars`): una barra
    /// en la mitad inferior sube el límite inferior a su `minY`; una barra
    /// en la mitad superior baja el límite superior a su `maxY`.
    ///
    /// Resuelve la mentira-en-verde #3 (issue #153): un elemento con frame
    /// y=829 en pantalla de 874pt está 100% dentro de los screen bounds pero
    /// DEBAJO del tab bar — el criterio de intersección cruda lo daba por
    /// visible y el tap posterior se perdía.
    public static func usableViewport(_ viewport: CGRect,
                                      safeFraction: CGFloat = defaultSafeFraction,
                                      occlusions: [CGRect] = []) -> CGRect {
        let inset = viewport.height * (1 - safeFraction) / 2
        var minY = viewport.minY + inset
        var maxY = viewport.maxY - inset
        for bar in occlusions where bar.intersects(viewport) {
            if bar.midY >= viewport.midY {
                maxY = min(maxY, bar.minY)   // barra inferior (tab bar)
            } else {
                minY = max(minY, bar.maxY)   // barra superior (nav bar)
            }
        }
        return CGRect(x: viewport.minX, y: minY,
                      width: viewport.width, height: max(0, maxY - minY))
    }

    /// Función pura frame+viewport → Bool (issue #153): true si el frame del
    /// elemento queda dentro del viewport ÚTIL cubriendo ≥ `minCoverage` de
    /// su área. Es `isVisible` pero contra `usableViewport` en vez del
    /// viewport crudo.
    public static func isInUsableViewport(frame: CGRect,
                                          viewport: CGRect,
                                          occlusions: [CGRect] = [],
                                          safeFraction: CGFloat = defaultSafeFraction,
                                          minCoverage: CGFloat = 0.5) -> Bool {
        let usable = usableViewport(viewport,
                                    safeFraction: safeFraction,
                                    occlusions: occlusions)
        return isVisible(frame: frame, inViewport: usable, minCoverage: minCoverage)
    }

    /// Detecta barras del sistema (tab bar / nav bar / toolbar) en el tree.
    /// Barato: el tree ya está en memoria cuando `scrollTo` lo consulta.
    /// Filtro geométrico: una "barra" cruza al menos media pantalla de ancho
    /// y no supera el 25% del alto (descarta paneles/sheets grandes).
    ///
    /// Roles cubiertos por serializador:
    /// - Observer iOS (ViewSerializer): `AXTabGroup` (UITabBar)
    /// - XCUI runner (RunnerSerialization): `TabBar`, `NavigationBar`, `Toolbar`
    /// - AX macOS: `AXTabBar`, `AXNavigationBar`, `AXToolbar`
    /// - Android: `...BottomNavigationView`, `...Toolbar`, `ActionBar`
    public static func occludingBars(in tree: [[String: Any]],
                                     screen: CGRect) -> [CGRect] {
        var bars: [CGRect] = []
        collectBars(in: tree, screen: screen, bars: &bars)
        return bars
    }

    private static func collectBars(in elements: [[String: Any]],
                                    screen: CGRect,
                                    bars: inout [CGRect]) {
        for el in elements {
            let role = (el["role"] as? String ?? "").lowercased()
            if isBarRole(role),
               let r = rect(from: el["frame"] as? [String: Any]),
               r.width >= screen.width * 0.5,
               r.height <= screen.height * 0.25 {
                bars.append(r)
            }
            if let children = el["children"] as? [[String: Any]] {
                collectBars(in: children, screen: screen, bars: &bars)
            }
        }
    }

    private static func isBarRole(_ role: String) -> Bool {
        return role.contains("tabbar") ||
               role.contains("tabgroup") ||
               role.contains("navigationbar") ||
               role.contains("toolbar") ||
               role.contains("actionbar") ||
               role.contains("bottomnavigation")
    }

    /// true si el elemento con `frame` vive DENTRO de una barra del tree
    /// (tab de un tab bar, botón de nav bar). Esos elementos son chrome fijo:
    /// siempre en pantalla y tappables aunque geométricamente caigan fuera
    /// del viewport útil — `scrollTo` no debe intentar scrollearlos ni
    /// declararlos ocluidos.
    public static func isBarDescendant(frame targetFrame: CGRect,
                                       in tree: [[String: Any]]) -> Bool {
        var result = false
        _ = findBarDescendant(in: tree, targetFrame: targetFrame,
                              underBar: false, result: &result)
        return result
    }

    @discardableResult
    private static func findBarDescendant(in elements: [[String: Any]],
                                          targetFrame: CGRect,
                                          underBar: Bool,
                                          result: inout Bool) -> Bool {
        for el in elements {
            let role = (el["role"] as? String ?? "").lowercased()
            let nowUnderBar = underBar || isBarRole(role)
            if let elRect = rect(from: el["frame"] as? [String: Any]),
               framesApproxEqual(elRect, targetFrame) {
                result = nowUnderBar
                return true
            }
            if let children = el["children"] as? [[String: Any]] {
                if findBarDescendant(in: children, targetFrame: targetFrame,
                                     underBar: nowUnderBar, result: &result) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Search direction → gesture (issue #153)

    /// `scrollTo X down` significa "el elemento está más ABAJO en el
    /// documento" (default, y lo que emite el recorder). El gesto que revela
    /// contenido de abajo es un swipe con el dedo hacia ARRIBA — y todos los
    /// backends (agente Android, adb legacy, XCUI runner, observer iOS)
    /// implementan `swipe` con semántica de GESTO. Sin esta inversión,
    /// `scrollTo X` swipeaba hacia el tope del documento y jamás alcanzaba
    /// un elemento below-the-fold (parte del bug #153: en el QA los swipes
    /// nunca acercaron el elemento al viewport).
    public static func swipeGesture(forSearchDirection direction: String) -> String {
        switch direction.lowercased() {
        case "down":  return "up"
        case "up":    return "down"
        case "left":  return "right"
        case "right": return "left"
        default:      return "up"
        }
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
