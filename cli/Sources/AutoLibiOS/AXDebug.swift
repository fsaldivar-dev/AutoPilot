import Foundation
import ApplicationServices

/// Debug utility to inspect all AX attributes of elements.
public struct AXDebug {

    /// Dump all attributes and children of elements matching a query.
    public static func inspect(root: AXUIElement, query: String, maxDepth: Int = 25) -> String {
        var output = ""
        inspectRecursive(element: root, query: query.lowercased(), depth: 0, maxDepth: maxDepth, output: &output)
        return output
    }

    private static func inspectRecursive(element: AXUIElement, query: String, depth: Int, maxDepth: Int, output: inout String) {
        guard depth < maxDepth else { return }

        // Get all children using multiple attribute names
        let childAttributes = [
            kAXChildrenAttribute,
            "AXVisibleChildren",
            "AXContents",
        ]

        for attrName in childAttributes {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attrName as CFString, &value)
            guard let children = value as? [AXUIElement] else { continue }

            for child in children {
                let info = elementInfo(child)
                let matches = info.lowercased().contains(query)

                if matches {
                    let indent = String(repeating: "  ", count: depth)
                    output += "\(indent)>>> MATCH: \(info)\n"
                    // Dump all attributes of this element
                    output += dumpAttributes(child, indent: indent + "    ")
                    // Also dump children
                    output += dumpChildrenDeep(child, indent: indent + "    ", depth: 0, maxDepth: 3)
                }

                inspectRecursive(element: child, query: query, depth: depth + 1, maxDepth: maxDepth, output: &output)
            }
        }
    }

    /// Get basic element info string.
    private static func elementInfo(_ element: AXUIElement) -> String {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title)
        var label: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXDescriptionAttribute as CFString, &label)
        var ident: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &ident)
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)

        let r = (role as? String) ?? "?"
        let t = (title as? String) ?? ""
        let l = (label as? String) ?? ""
        let i = (ident as? String) ?? ""
        let v = (value as? String) ?? ""

        var s = r
        if !t.isEmpty { s += " \"\(t)\"" }
        if !l.isEmpty && l != t { s += " label=\"\(l)\"" }
        if !i.isEmpty { s += " id=\(i)" }
        if !v.isEmpty && v != t { s += " value=\"\(v)\"" }
        return s
    }

    /// List all attribute names and their values for an element.
    private static func dumpAttributes(_ element: AXUIElement, indent: String) -> String {
        var output = ""
        var names: CFArray?
        AXUIElementCopyAttributeNames(element, &names)
        guard let attrNames = names as? [String] else { return output }

        for attr in attrNames.sorted() {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attr as CFString, &value)

            if let arr = value as? [AXUIElement] {
                output += "\(indent)\(attr): [\(arr.count) elements]\n"
                for (i, child) in arr.prefix(5).enumerated() {
                    output += "\(indent)  [\(i)] \(elementInfo(child))\n"
                }
            } else if let str = value as? String {
                output += "\(indent)\(attr): \"\(str)\"\n"
            } else if let num = value as? NSNumber {
                output += "\(indent)\(attr): \(num)\n"
            } else if value != nil {
                output += "\(indent)\(attr): \(type(of: value!))\n"
            }
        }
        return output
    }

    /// Recursively dump children to find hidden elements.
    private static func dumpChildrenDeep(_ element: AXUIElement, indent: String, depth: Int, maxDepth: Int) -> String {
        guard depth < maxDepth else { return "" }
        var output = ""

        let childAttributes = [kAXChildrenAttribute, "AXVisibleChildren", "AXContents", "AXToolbarItems"]

        for attrName in childAttributes {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attrName as CFString, &value)
            guard let children = value as? [AXUIElement], !children.isEmpty else { continue }

            for child in children {
                output += "\(indent)child: \(elementInfo(child))\n"
                output += dumpChildrenDeep(child, indent: indent + "  ", depth: depth + 1, maxDepth: maxDepth)
            }
        }
        return output
    }
}
