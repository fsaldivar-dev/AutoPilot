import Foundation
import AutoCore

/// Filtro de `auto list <tipo>` sobre el árbol del observer / DeviceBridge.tree.
///
/// #150: el observer emite árbol ANIDADO (children) — el filtro recorre el
/// árbol completo con TreeQuery en vez de asumir la lista plana anterior.
/// Reusa la taxonomía de roles AX que el observer ya emite, así `list` se
/// resuelve sin el roundtrip de typed-queries del runner XCUI.
public enum iOSListFilter {

    /// Nodos del árbol cuyo role AX corresponde al tipo pedido. Tipo
    /// desconocido → lista vacía (el caller ya validó contra allowedTypes).
    public static func filter(tree: [[String: Any]], type: String) -> [[String: Any]] {
        let wanted: Set<String>
        switch type.lowercased() {
        case "all":                         return TreeQuery.flatten(tree)
        case "buttons":                     wanted = ["AXButton"]
        case "labels", "statictexts":       wanted = ["AXStaticText"]
        case "textfields":                  wanted = ["AXTextField", "AXTextArea"]
        case "cells":                       wanted = ["AXCell"]
        case "switches":                    wanted = ["AXCheckBox", "AXSwitch"]
        case "links":                       wanted = ["AXLink"]
        case "images":                      wanted = ["AXImage"]
        case "navbars", "navigationbars":   wanted = ["AXNavigationBar"]
        default:                            return []
        }
        return TreeQuery.flatten(tree).filter { node in
            guard let role = node["role"] as? String else { return false }
            return wanted.contains(role)
        }
    }
}
