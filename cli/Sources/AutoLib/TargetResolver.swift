import Foundation
import ApplicationServices

/// Resolves element targets with duplicate handling.
/// Supports: "Login", "Camera[2]", "$5"
public struct TargetResolver {

    /// Parse a target string into label and optional index.
    /// "Camera[2]" → ("Camera", 2)
    /// "Camera" → ("Camera", nil)
    /// "$5" → (nil, nil) — handled separately
    public static func parse(_ target: String) -> (label: String, index: Int?) {
        // Check for [N] suffix
        if let bracket = target.lastIndex(of: "["),
           let end = target.lastIndex(of: "]"),
           bracket < end {
            let label = String(target[target.startIndex..<bracket])
            let numStr = String(target[target.index(after: bracket)..<end])
            if let n = Int(numStr) {
                return (label, n)
            }
        }
        return (target, nil)
    }

    /// Find all elements matching a label, return them with occurrence index.
    public static func findAll(in root: AXUIElement, matching label: String) -> [(element: AXUIElement, occurrence: Int)] {
        var results: [(AXUIElement, Int)] = []
        var count = 0
        findRecursive(element: root, query: label.lowercased(), results: &results, count: &count, depth: 0, maxDepth: 20)
        return results
    }

    private static func findRecursive(element: AXUIElement, query: String, results: inout [(AXUIElement, Int)], count: inout Int, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }

        for child in children {
            // Get all text attributes
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descRef)
            var identRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identRef)
            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef)

            let title = (titleRef as? String) ?? ""
            let desc = (descRef as? String) ?? ""
            let ident = (identRef as? String) ?? ""
            let value = (valueRef as? String) ?? ""

            let matches = title.lowercased().contains(query) ||
                         desc.lowercased().contains(query) ||
                         ident.lowercased().contains(query) ||
                         value.lowercased().contains(query) ||
                         title.lowercased() == query ||
                         desc.lowercased() == query

            if matches {
                count += 1
                results.append((child, count))
            }

            findRecursive(element: child, query: query, results: &results, count: &count, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}
