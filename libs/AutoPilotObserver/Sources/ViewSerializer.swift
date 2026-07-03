import UIKit

enum ViewSerializer {

    // #150: paridad cross-platform con el agente Android (TreeSerializer.kt).
    // El árbol es ANIDADO (key "children") y cada nodo emite el mismo set de
    // keys core que Android: role, title, label, identifier, value, enabled,
    // clickable, scrollable, focused, package, frame, children. Las keys se
    // emiten SIEMPRE (aunque el valor sea "" / false), igual que Android, para
    // que el mismo test suite de parity valide ambos shapes (ARD-002 RFC).
    //
    // Mapeo UIKit → keys Android, con las divergencias honestas:
    //   - title:      texto visible (UILabel.text / UIButton title). Los nodos
    //                  AX de SwiftUI exponen UNA sola string (accessibilityLabel,
    //                  que va en `label`); no existe un `text` separado como el
    //                  node.text de Android, así que en esos nodos title = "".
    //   - value:      accessibilityValue, o el texto actual de UITextField /
    //                  UITextView (#166).
    //   - enabled:    UIControl.isEnabled; en nodos AX el trait .notEnabled.
    //                  Views no-control no tienen enabled en UIKit → true
    //                  (igual que un TextView Android).
    //   - clickable:  aproximación — UIKit no expone "tiene handler" como el
    //                  isClickable de Android: UIControl, tap gesture
    //                  recognizer, o trait .button/.link.
    //   - scrollable: UIScrollView.isScrollEnabled. Android reporta el
    //                  isScrollable del nodo AX; es el equivalente más cercano
    //                  sin inspeccionar contentSize (que flapea durante layout).
    //   - focused:    isFirstResponder (foco de input). Android reporta el
    //                  foco de AccessibilityNodeInfo — semántica análoga.
    //   - package:    Bundle.main.bundleIdentifier. Android lo emite por nodo
    //                  porque su árbol puede mezclar ventanas de otros paquetes
    //                  (IME, system); el observer vive in-process, así que es
    //                  constante — se emite igual por nodo para paridad.
    // Keys extra iOS-only: `class` (clase UIKit concreta) y `placeholder`
    // (#166). No rompen parity: los consumidores compartidos las ignoran.

    private static let packageName = Bundle.main.bundleIdentifier ?? ""

    static func serialize(maxDepth: Int = 20) -> [[String: Any]] {
        // `visited` dedupes objects reachable by more than one path — a view
        // can appear BOTH in a container's accessibilityElements AND as a
        // subview (we intentionally walk both, see below), which used to
        // serialize entire subtrees several times on tabbed screens. With the
        // nested shape (#150) the node lands under whichever parent reached
        // it first, and only once.
        var visited = Set<ObjectIdentifier>()
        return allWindows().compactMap { serializeView($0, depth: 0, maxDepth: maxDepth, visited: &visited) }
    }

    // MARK: - UIView tree walk

    private static func serializeView(_ view: UIView, depth: Int, maxDepth: Int,
                                      visited: inout Set<ObjectIdentifier>) -> [String: Any]? {
        guard depth < maxDepth else { return nil }
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        // Skip retained-but-detached views (e.g. views of non-selected tabs
        // that SwiftUI/UIKit keeps alive and still lists in some container's
        // accessibilityElements) — they are not on screen.
        guard view is UIWindow || view.window != nil else { return nil }
        guard visited.insert(ObjectIdentifier(view)).inserted else { return nil }

        let className = String(describing: type(of: view))
        let screenFrame = view.superview?.convert(view.frame, to: nil) ?? view.frame

        // title — texto principal visible (paridad con node.text de Android).
        var title = ""
        if let text = (view as? UILabel)?.text { title = text }
        if let btn = view as? UIButton,
           let t = btn.title(for: .normal), !t.isEmpty { title = t }

        // value — accessibilityValue (switches, sliders) o texto de inputs (#166).
        var value = view.accessibilityValue ?? ""
        if let tf = view as? UITextField, let t = tf.text, !t.isEmpty { value = t }
        if let tv = view as? UITextView, let t = tv.text, !t.isEmpty { value = t }

        var node: [String: Any] = [
            "role": axRole(for: view),
            "class": className,
            "title": title,
            "label": view.accessibilityLabel ?? "",
            "identifier": view.accessibilityIdentifier ?? "",
            "value": value,
            "enabled": (view as? UIControl)?.isEnabled ?? true,
            "clickable": isClickable(view),
            "scrollable": (view as? UIScrollView)?.isScrollEnabled ?? false,
            "focused": view.isFirstResponder,
            "package": packageName,
            "frame": frameDict(screenFrame)
        ]
        // #166: exponer el placeholder de los text inputs. Un TextField SwiftUI
        // plano NO pone accessibilityLabel = placeholder (a diferencia de
        // UISearchBar), así que sin esto el campo es un AXTextField anónimo y
        // `type "Titulo de tu experiencia" "..."` no puede resolverlo por label.
        if let ph = (view as? UITextField)?.placeholder, !ph.isEmpty {
            node["placeholder"] = ph
        }

        var children: [[String: Any]] = []

        // Walk BOTH accessibility elements AND subviews — some UIKit containers
        // (UINavigationBar, UIToolbar) expose a partial accessibilityElements list
        // but keep the real interactive controls as subviews. Walking both avoids
        // missing toolbar buttons like "Cancelar" / "Guardar".
        if let axElems = view.accessibilityElements, !axElems.isEmpty {
            for elem in axElems {
                if let child = serializeAXElem(elem, depth: depth + 1, maxDepth: maxDepth, visited: &visited) {
                    children.append(child)
                }
            }
        }
        for sub in view.subviews {
            if let child = serializeView(sub, depth: depth + 1, maxDepth: maxDepth, visited: &visited) {
                children.append(child)
            }
        }

        // UIBarButtonItems are NOT UIViews and don't live in the accessibility tree
        // for SwiftUI navigation bars. Walk UINavigationBar.items / UIToolbar.items
        // directly to expose "Cancelar" / "Guardar" / "Done" etc.
        if let navBar = view as? UINavigationBar {
            for item in (navBar.items ?? []) {
                let all = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
                for bbi in all {
                    if let child = serializeBarButtonItem(bbi) { children.append(child) }
                }
            }
        } else if let toolbar = view as? UIToolbar {
            for bbi in (toolbar.items ?? []) {
                if let child = serializeBarButtonItem(bbi) { children.append(child) }
            }
        }

        node["children"] = children
        return node
    }

    /// Aproximación de `isClickable` de Android — UIKit no expone "tiene un
    /// handler de tap", así que reportamos lo observable: es un UIControl,
    /// tiene un UITapGestureRecognizer, o declara traits de botón/link.
    private static func isClickable(_ view: UIView) -> Bool {
        guard view.isUserInteractionEnabled else { return false }
        if view is UIControl { return true }
        if let recognizers = view.gestureRecognizers,
           recognizers.contains(where: { $0 is UITapGestureRecognizer }) { return true }
        let traits = view.accessibilityTraits
        return traits.contains(.button) || traits.contains(.link)
    }

    private static func serializeBarButtonItem(_ bbi: UIBarButtonItem) -> [String: Any]? {
        // Read label from AX first (respects custom accessibilityLabel), fall back to title.
        let label = bbi.accessibilityLabel ?? bbi.title ?? ""
        let id = bbi.accessibilityIdentifier ?? ""
        // Frame: UIBarButtonItem stores it internally in its view; accessibilityFrame works.
        let frame = bbi.accessibilityFrame
        if label.isEmpty && id.isEmpty && frame == .zero { return nil }

        return [
            "role": "AXButton",
            "class": "UIBarButtonItem",
            "title": bbi.title ?? "",
            "label": label,
            "identifier": id,
            "value": "",
            "enabled": bbi.isEnabled,
            "clickable": true,
            "scrollable": false,
            "focused": false,
            "package": packageName,
            "frame": frameDict(frame),
            "children": [[String: Any]]()
        ]
    }

    private static func serializeAXElem(_ elem: Any, depth: Int, maxDepth: Int,
                                        visited: inout Set<ObjectIdentifier>) -> [String: Any]? {
        guard depth < maxDepth else { return nil }

        // UIView subclass in the AX list → recurse as a normal view
        if let view = elem as? UIView { return serializeView(view, depth: depth, maxDepth: maxDepth, visited: &visited) }

        // Treat any NSObject-based AX element (UIAccessibilityElement,
        // SwiftUI.AccessibilityNode, or any other NSObject that responds
        // to the informal UIAccessibility protocol) as a generic AX node.
        let obj = elem as AnyObject
        guard visited.insert(ObjectIdentifier(obj)).inserted else { return nil }
        let traits = obj.accessibilityTraits ?? []
        let frame  = obj.accessibilityFrame ?? .zero

        var node: [String: Any] = [
            "role": axRole(forTraits: traits),
            // SwiftUI AX nodes expose ONE string (accessibilityLabel) — no
            // separate displayed text like Android's node.text (see header).
            "title": "",
            "label": (obj.accessibilityLabel ?? nil) ?? "",
            "identifier": (obj.accessibilityIdentifier ?? nil) ?? "",
            "value": (obj.accessibilityValue ?? nil) ?? "",
            "enabled": !traits.contains(.notEnabled),
            "clickable": traits.contains(.button) || traits.contains(.link),
            "scrollable": false,
            "focused": false,
            "package": packageName,
            "frame": frameDict(frame)
        ]

        var children: [[String: Any]] = []
        // Recurse into compound AX containers — SwiftUI builds composite buttons
        // (icon + label) as an AccessibilityNode with nested accessibilityElements.
        // Flatten the double-optional from AnyObject protocol lookup.
        let rawChildren: [Any]?? = obj.accessibilityElements
        if let elems = rawChildren?.flatMap({ $0 }), !elems.isEmpty {
            for child in elems {
                if let c = serializeAXElem(child, depth: depth + 1, maxDepth: maxDepth, visited: &visited) {
                    children.append(c)
                }
            }
        }
        node["children"] = children
        return node
    }

    // MARK: - Fuzzy candidate collection

    /// A tappable element found by fuzzy matching, tagged by kind so the
    /// caller can dispatch the right activation path.
    enum Candidate {
        case view(UIView)
        case axElement(AnyObject)
        case barButton(UIBarButtonItem)
    }

    /// Collects every on-screen element whose label / identifier / text /
    /// title satisfies `predicate`, deduplicated by identity. Used by the tap
    /// fallback (exact → prefix → contains); the returned `label` is what the
    /// element matched with, for ambiguity error messages.
    static func collectCandidates(where predicate: (String) -> Bool) -> [(object: Candidate, label: String)] {
        var visited = Set<ObjectIdentifier>()
        var out: [(object: Candidate, label: String)] = []
        for window in allWindows() {
            collectInView(window, predicate: predicate, visited: &visited, out: &out)
        }
        return out
    }

    private static func collectInView(_ view: UIView, predicate: (String) -> Bool,
                                      visited: inout Set<ObjectIdentifier>,
                                      out: inout [(object: Candidate, label: String)]) {
        guard !view.isHidden, view.alpha > 0.01 else { return }
        guard view is UIWindow || view.window != nil else { return }
        guard visited.insert(ObjectIdentifier(view)).inserted else { return }

        let keys = [view.accessibilityLabel, view.accessibilityIdentifier,
                    (view as? UILabel)?.text, (view as? UIButton)?.title(for: .normal),
                    (view as? UITextField)?.placeholder]  // #166: match por placeholder
        if let matched = firstMatch(keys, predicate) {
            out.append((.view(view), matched))
        }

        if let axElems = view.accessibilityElements {
            for elem in axElems {
                collectInAXElem(elem, predicate: predicate, visited: &visited, out: &out)
            }
        }
        for sub in view.subviews {
            collectInView(sub, predicate: predicate, visited: &visited, out: &out)
        }

        if let navBar = view as? UINavigationBar {
            for item in (navBar.items ?? []) {
                let all = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
                for bbi in all { collectBarButton(bbi, predicate: predicate, visited: &visited, out: &out) }
            }
        } else if let toolbar = view as? UIToolbar {
            for bbi in (toolbar.items ?? []) {
                collectBarButton(bbi, predicate: predicate, visited: &visited, out: &out)
            }
        }
    }

    private static func collectInAXElem(_ elem: Any, predicate: (String) -> Bool,
                                        visited: inout Set<ObjectIdentifier>,
                                        out: inout [(object: Candidate, label: String)]) {
        if let view = elem as? UIView {
            collectInView(view, predicate: predicate, visited: &visited, out: &out)
            return
        }
        let obj = elem as AnyObject
        guard visited.insert(ObjectIdentifier(obj)).inserted else { return }

        let keys = [(obj.accessibilityLabel ?? nil), (obj.accessibilityIdentifier ?? nil)]
        if let matched = firstMatch(keys, predicate) {
            out.append((.axElement(obj), matched))
        }

        let raw: [Any]?? = obj.accessibilityElements
        if let children = raw?.flatMap({ $0 }) {
            for child in children {
                collectInAXElem(child, predicate: predicate, visited: &visited, out: &out)
            }
        }
    }

    private static func collectBarButton(_ bbi: UIBarButtonItem, predicate: (String) -> Bool,
                                         visited: inout Set<ObjectIdentifier>,
                                         out: inout [(object: Candidate, label: String)]) {
        guard visited.insert(ObjectIdentifier(bbi)).inserted else { return }
        let keys = [bbi.accessibilityLabel, bbi.title, bbi.accessibilityIdentifier]
        if let matched = firstMatch(keys, predicate) {
            out.append((.barButton(bbi), matched))
        }
    }

    private static func firstMatch(_ keys: [String?], _ predicate: (String) -> Bool) -> String? {
        for key in keys {
            if let k = key, !k.isEmpty, predicate(k) { return k }
        }
        return nil
    }

    // MARK: - Element finder

    /// Finds a UIView by accessibility label / identifier / text.
    static func findView(matching target: String) -> UIView? {
        for window in allWindows() {
            if let found = searchView(window, target: target) { return found }
        }
        return nil
    }

    /// Finds an AX element (SwiftUI AccessibilityNode, UIAccessibilityElement, or
    /// any NSObject implementing the informal UIAccessibility protocol) by label
    /// or identifier when UIView search fails.
    static func findAXElement(matching target: String) -> AnyObject? {
        for window in allWindows() {
            if let found = searchAXElems(in: window, target: target) { return found }
        }
        return nil
    }

    /// Finds a UIBarButtonItem (Cancelar / Guardar / Done in UINavigationBar or UIToolbar).
    /// These are not UIViews and don't appear in the standard AX tree search.
    static func findBarButtonItem(matching target: String) -> UIBarButtonItem? {
        for window in allWindows() {
            if let found = searchBarButtons(in: window, target: target) { return found }
        }
        return nil
    }

    private static func searchBarButtons(in view: UIView, target: String) -> UIBarButtonItem? {
        if let navBar = view as? UINavigationBar {
            for item in (navBar.items ?? []) {
                let all = (item.leftBarButtonItems ?? []) + (item.rightBarButtonItems ?? [])
                for bbi in all {
                    if matches(bbi, target: target) { return bbi }
                }
            }
        } else if let toolbar = view as? UIToolbar {
            for bbi in (toolbar.items ?? []) {
                if matches(bbi, target: target) { return bbi }
            }
        }
        for sub in view.subviews {
            if !sub.isHidden, sub.alpha > 0.01 {
                if let found = searchBarButtons(in: sub, target: target) { return found }
            }
        }
        return nil
    }

    private static func matches(_ bbi: UIBarButtonItem, target: String) -> Bool {
        let label = bbi.accessibilityLabel ?? ""
        let title = bbi.title ?? ""
        let id = bbi.accessibilityIdentifier ?? ""
        return label == target || title == target || id == target
    }

    private static func searchView(_ view: UIView, target: String) -> UIView? {
        if view.isHidden || view.alpha < 0.01 { return nil }

        let label = view.accessibilityLabel ?? ""
        let id    = view.accessibilityIdentifier ?? ""
        let text  = (view as? UILabel)?.text ?? ""
        let title = (view as? UIButton)?.title(for: .normal) ?? ""
        let placeholder = (view as? UITextField)?.placeholder ?? ""  // #166

        if label == target || id == target || text == target || title == target
            || (!placeholder.isEmpty && placeholder == target) { return view }

        for sub in view.subviews {
            if let found = searchView(sub, target: target) { return found }
        }
        return nil
    }

    /// Searches `accessibilityElements` lists recursively across both the UIView
    /// hierarchy AND the AX element tree. Accepts any NSObject implementing the
    /// informal UIAccessibility protocol (UIAccessibilityElement AND
    /// SwiftUI.AccessibilityNode). SwiftUI groups related elements (PIN keypad,
    /// toolbar) inside a container AccessibilityNode whose own
    /// `accessibilityElements` holds the children — must recurse into those.
    private static func searchAXElems(in view: UIView, target: String) -> AnyObject? {
        if let axElems = view.accessibilityElements {
            for elem in axElems {
                if let found = matchAXElement(elem, target: target) { return found }
            }
        }
        for sub in view.subviews {
            if !sub.isHidden, sub.alpha > 0.01 {
                if let found = searchAXElems(in: sub, target: target) { return found }
            }
        }
        return nil
    }

    /// Recursively matches an AX element (AccessibilityNode / UIAccessibilityElement)
    /// by label or identifier, descending into its own accessibilityElements
    /// if present (SwiftUI container AccessibilityNodes).
    private static func matchAXElement(_ elem: Any, target: String) -> AnyObject? {
        let obj = elem as AnyObject
        let label: String = (obj.accessibilityLabel ?? nil) ?? ""
        let id:    String = (obj.accessibilityIdentifier ?? nil) ?? ""
        if label == target || id == target { return obj }

        // Recurse into this AX element's own children (if any).
        let raw: [Any]?? = obj.accessibilityElements
        if let children = raw?.flatMap({ $0 }) {
            for child in children {
                if let found = matchAXElement(child, target: target) { return found }
            }
        }
        return nil
    }

    // MARK: - Helpers

    private static func allWindows() -> [UIWindow] {
        if #available(iOS 13, *) {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
        }
        return UIApplication.shared.windows
    }

    private static func frameDict(_ r: CGRect) -> [String: Any] {
        ["x": Int(r.origin.x), "y": Int(r.origin.y),
         "width": Int(r.size.width), "height": Int(r.size.height)]
    }

    private static func axRole(for view: UIView) -> String {
        switch view {
        case is UIButton:         return "AXButton"
        case is UITextField:      return "AXTextField"
        case is UITextView:       return "AXTextArea"
        case is UILabel:          return "AXStaticText"
        case is UISwitch:         return "AXCheckBox"
        case is UISlider:         return "AXSlider"
        case is UIImageView:      return "AXImage"
        case is UIScrollView:     return "AXScrollArea"
        case is UINavigationBar:  return "AXNavigationBar"
        case is UITabBar:         return "AXTabGroup"
        case is UIWindow:         return "AXWindow"
        case is UITableView:      return "AXTable"
        case is UICollectionView: return "AXOutline"
        case is UIControl:        return "AXButton"
        default:                  return "AXGroup"
        }
    }

    private static func axRole(forTraits traits: UIAccessibilityTraits) -> String {
        if traits.contains(.button)     { return "AXButton" }
        if traits.contains(.link)       { return "AXLink" }
        if traits.contains(.header)     { return "AXHeading" }
        if traits.contains(.image)      { return "AXImage" }
        if traits.contains(.staticText) { return "AXStaticText" }
        if traits.contains(.adjustable) { return "AXSlider" }
        if traits.contains(.searchField){ return "AXTextField" }
        return "AXGroup"
    }
}
