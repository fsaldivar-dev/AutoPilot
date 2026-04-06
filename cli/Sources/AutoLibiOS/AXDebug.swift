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

    /// Show parent chain and within candidates for matched elements.
    /// Useful for understanding scope and crafting `within` selectors.
    public static func inspectWithContext(root: AXUIElement, query: String) -> String {
        var output = ""
        let matches = TargetResolver.findAll(in: root, matching: query)

        if matches.isEmpty {
            output += "No matches for '\(query)'\n"
            return output
        }

        output += "\(matches.count) match(es) for '\(query)':\n\n"

        for (element, occurrence) in matches {
            let info = elementInfo(element)

            // Check if it has an identifier
            var identRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &identRef)
            let hasId = ((identRef as? String) ?? "").isEmpty == false

            output += "  [\(occurrence)] \(info)"
            if hasId {
                output += "  \u{2705}"
            } else {
                output += "  \u{26A0}\u{FE0F}  no accessibilityIdentifier"
            }
            output += "\n"

            // Walk parent chain
            output += "      Parent chain:\n"
            var current: AXUIElement = element
            var depth = 0
            while let parent = axGetParent(of: current), depth < 8 {
                let parentInfo = elementInfo(parent)
                let parentHasId = axHasIdentifier(parent)
                let parentRole = axGetRole(of: parent)
                let isContainer = isContainerRole(parentRole)

                var marker = "   "
                if parentHasId { marker = " \u{2605} " }          // star — has identifier, best within
                else if isContainer { marker = " \u{25C6} " }     // diamond — container, ok within

                output += "       \(marker) \(parentInfo)\n"
                current = parent
                depth += 1
            }

            output += "\n"
        }

        // Suggest within if multiple matches
        if matches.count > 1 {
            output += "  \u{26A0}\u{FE0F}  \(matches.count) matches \u{2014} consider using 'within' to scope:\n\n"

            for (element, occurrence) in matches {
                if let ancestor = findBestAncestor(of: element) {
                    output += "      [\(occurrence)] tap \"\(query)\" within \"\(ancestor)\"\n"
                } else {
                    output += "      [\(occurrence)] tap \"\(query)[\(occurrence)]\"  (no good ancestor found)\n"
                }
            }
            output += "\n"
        }

        return output
    }

    // MARK: - Context helpers (public for SemanticResolver)

    public static func axGetParent(of element: AXUIElement) -> AXUIElement? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &ref)
        return ref as! AXUIElement?
    }

    public static func axGetRole(of element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &ref)
        return ref as? String
    }

    public static func axHasIdentifier(_ element: AXUIElement) -> Bool {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXIdentifierAttribute as CFString, &ref)
        return ((ref as? String) ?? "").isEmpty == false
    }

    public static func isContainerRole(_ role: String?) -> Bool {
        guard let role else { return false }
        let containers = ["AXToolbar", "AXNavigationBar", "AXTabBar", "AXTable",
                          "AXScrollArea", "AXGroup", "AXList", "AXOutline",
                          "AXSheet", "AXWindow"]
        return containers.contains(role)
    }

    /// Walk parent chain and find the best ancestor for a `within` clause.
    /// Prefers ancestors with accessibilityIdentifier, then named containers.
    public static func findBestAncestor(of element: AXUIElement) -> String? {
        var current: AXUIElement = element
        var bestLabel: String? = nil
        var bestScore = 0
        var depth = 0

        while let parent = axGetParent(of: current), depth < 10 {
            var score = 0
            if axHasIdentifier(parent) { score += 10 }
            if isContainerRole(axGetRole(of: parent)) { score += 5 }

            // Get label for this ancestor
            var identRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXIdentifierAttribute as CFString, &identRef)
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXTitleAttribute as CFString, &titleRef)
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(parent, kAXDescriptionAttribute as CFString, &descRef)

            let label = (identRef as? String).flatMap({ $0.isEmpty ? nil : $0 })
                     ?? (titleRef as? String).flatMap({ $0.isEmpty ? nil : $0 })
                     ?? (descRef as? String).flatMap({ $0.isEmpty ? nil : $0 })

            if let label, score > bestScore {
                bestScore = score
                bestLabel = label
            }

            current = parent
            depth += 1
        }

        return bestLabel
    }

    // MARK: - Inspect (original)

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
