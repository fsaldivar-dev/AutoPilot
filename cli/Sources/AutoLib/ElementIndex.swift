import Foundation
import ApplicationServices

/// Maintains an indexed list of AX elements for reference by $N syntax.
/// The index is stable as long as the UI doesn't change.
public final class ElementIndex {

    public struct Entry {
        public let index: Int
        public let role: String
        public let label: String
        public let id: String
        public let frame: String
        public let element: AXUIElement
    }

    private var entries: [Entry] = []

    public init() {}

    /// Rebuild the index from the current AX tree.
    public func rebuild(from root: AXUIElement) {
        entries = []
        collectElements(element: root, depth: 0, maxDepth: 20)
    }

    /// Get element by index.
    public func get(_ index: Int) -> Entry? {
        guard index >= 0 && index < entries.count else { return nil }
        return entries[index]
    }

    /// Get all entries.
    public var all: [Entry] { entries }

    /// Count of indexed elements.
    public var count: Int { entries.count }

    /// Find entries matching a label/id.
    public func find(_ query: String) -> [Entry] {
        let q = query.lowercased()
        return entries.filter {
            $0.label.lowercased().contains(q) ||
            $0.id.lowercased().contains(q)
        }
    }

    /// Print the index as a formatted table.
    public func printIndex() {
        for entry in entries {
            let idx = "$\(entry.index)".padding(toLength: 5, withPad: " ", startingAt: 0)
            let role = entry.role.replacingOccurrences(of: "AX", with: "").padding(toLength: 12, withPad: " ", startingAt: 0)
            let label = entry.label.isEmpty ? entry.id : entry.label
            let display = label.isEmpty ? "(no label)" : "\"\(label)\""
            print("\(idx) \(role) \(display.padding(toLength: 30, withPad: " ", startingAt: 0)) \(entry.frame)")
        }
    }

    // MARK: - Private

    private func collectElements(element: AXUIElement, depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return }

        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = (roleRef as? String) ?? ""

            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            var descRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXDescriptionAttribute as CFString, &descRef)
            let desc = (descRef as? String) ?? ""

            var identRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXIdentifierAttribute as CFString, &identRef)
            let ident = (identRef as? String) ?? ""

            var valueRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXValueAttribute as CFString, &valueRef)
            let value = (valueRef as? String) ?? ""

            // Build frame string
            var frame = ""
            var posRef: CFTypeRef?
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
            if let posVal = posRef, let sizeVal = sizeRef {
                var pos = CGPoint.zero
                var sz = CGSize.zero
                AXValueGetValue(posVal as! AXValue, .cgPoint, &pos)
                AXValueGetValue(sizeVal as! AXValue, .cgSize, &sz)
                frame = "[\(Int(pos.x)),\(Int(pos.y)) \(Int(sz.width))x\(Int(sz.height))]"
            }

            let label = !desc.isEmpty ? desc : (!title.isEmpty ? title : value)

            // Only index interactive/visible elements (skip containers with no label)
            let isInteractive = role.contains("Button") || role.contains("TextField") ||
                               role.contains("TextArea") || role.contains("CheckBox") ||
                               role.contains("Slider") || role.contains("Tab")
            let hasLabel = !label.isEmpty || !ident.isEmpty
            let isText = role.contains("StaticText") || role.contains("Heading") || role.contains("Image")

            if isInteractive || (hasLabel && isText) {
                entries.append(Entry(
                    index: entries.count,
                    role: role,
                    label: label,
                    id: ident,
                    frame: frame,
                    element: child
                ))
            }

            collectElements(element: child, depth: depth + 1, maxDepth: maxDepth)
        }
    }
}
