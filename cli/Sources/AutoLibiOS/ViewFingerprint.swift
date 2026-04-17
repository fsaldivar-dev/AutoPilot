import Foundation
import ApplicationServices
import AutoCore

// iOS-specific capture of a ViewFingerprint from an AXUIElement. Lives
// here instead of AutoCore because ApplicationServices is macOS-only.
// The struct itself is in AutoCore/ViewFingerprint.swift.

public extension ViewFingerprint {

    /// Capture a cheap snapshot of the AX root (typically the Simulator
    /// window content). Reads role/title/identifier/frame for each of the
    /// first `maxChildren` immediate children, plus `maxGrandchildren`
    /// grandchildren per child. One XPC per attribute per node — worst
    /// case ~6 * 5 * 4 = ~120 XPC per capture at defaults, but typical
    /// iOS view hierarchies settle under ~40 XPC = 30-60ms wall clock.
    /// Push/pop transitions change the immediate children of root, so
    /// maxGrandchildren=1 is enough to detect most real UI changes.
    static func capture(root: AXUIElement,
                        maxChildren: Int = 6,
                        maxGrandchildren: Int = 1) -> ViewFingerprint {
        guard let children = axChildren(of: root) else {
            return ViewFingerprint(rootChildCount: 0, topLevelSignature: "")
        }
        var parts: [String] = []
        parts.reserveCapacity(maxChildren * (1 + maxGrandchildren))

        for child in children.prefix(maxChildren) {
            parts.append(axSignature(child))
            if let grand = axChildren(of: child) {
                for g in grand.prefix(maxGrandchildren) {
                    parts.append("·" + axSignature(g))
                }
            }
        }
        return ViewFingerprint(rootChildCount: children.count,
                               topLevelSignature: parts.joined(separator: "|"))
    }

    // MARK: - Private AX helpers

    private static func axChildren(of element: AXUIElement) -> [AXUIElement]? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        return value as? [AXUIElement]
    }

    private static func axString(_ element: AXUIElement, _ attr: CFString) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attr, &value)
        return (value as? String) ?? ""
    }

    private static func axFrame(_ element: AXUIElement) -> String {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posRef)
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeRef)
        var pos = CGPoint.zero
        var size = CGSize.zero
        if let posRef = posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) }
        if let sizeRef = sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }
        return "\(Int(pos.x)),\(Int(pos.y)),\(Int(size.width)),\(Int(size.height))"
    }

    private static func axSignature(_ element: AXUIElement) -> String {
        let role = axString(element, kAXRoleAttribute as CFString)
        let title = axString(element, kAXTitleAttribute as CFString)
        let ident = axString(element, kAXIdentifierAttribute as CFString)
        let frame = axFrame(element)
        return "\(role):\(ident.isEmpty ? title : ident):\(frame)"
    }
}
