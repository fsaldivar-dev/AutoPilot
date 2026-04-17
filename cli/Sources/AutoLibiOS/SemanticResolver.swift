import Foundation
import ApplicationServices
import AutoCore

// MARK: - SemanticResolver

/// Resolves a screen coordinate to a semantic selector by inspecting the AX tree.
public struct SemanticResolver {

    /// Resolve a click at screen coordinate to a semantic action.
    public static func resolveClick(
        at point: CGPoint,
        root: AXUIElement,
        command: String = "tap"
    ) -> ResolvedAction {
        // 1. Hit-test: find element at coordinate
        guard let element = hitTest(at: point, root: root) else {
            // Fallback: coordinate-based tap
            return ResolvedAction(
                command: "tapAt",
                selector: "\(Int(point.x)) \(Int(point.y))",
                role: nil, within: nil, occurrence: nil,
                identifier: nil, fragile: true, coordinate: point
            )
        }

        // 2. Extract attributes
        let attrs = extractAttributes(element)

        // 3. Choose best selector
        let (selector, usedIdentifier) = chooseBestSelector(attrs)

        // If no text at all, fall back to coordinate
        guard let selector else {
            return ResolvedAction(
                command: "tapAt",
                selector: "\(Int(point.x)) \(Int(point.y))",
                role: nil, within: nil, occurrence: nil,
                identifier: attrs.identifier, fragile: true, coordinate: point
            )
        }

        // 4. Check uniqueness in tree
        let allMatches = TargetResolver.findAll(in: root, matching: selector)
        let matchCount = allMatches.count

        if matchCount <= 1 {
            // Unique — simple selector, no role or within needed
            return ResolvedAction(
                command: command,
                selector: selector,
                role: nil, within: nil, occurrence: nil,
                identifier: usedIdentifier ? attrs.identifier : nil,
                fragile: !usedIdentifier,
                coordinate: point
            )
        }

        // 5. Multiple matches — try to disambiguate

        // 5a. Try role filter
        let roleShort = shortRole(attrs.role)
        if let roleShort {
            let roleMatches = TargetResolver.findAll(
                in: root, matching: selector,
                scope: nil, requiredRole: roleShort
            )
            if roleMatches.count == 1 {
                return ResolvedAction(
                    command: command,
                    selector: selector,
                    role: roleShort, within: nil, occurrence: nil,
                    identifier: usedIdentifier ? attrs.identifier : nil,
                    fragile: false,
                    coordinate: point
                )
            }
        }

        // 5b. Try within scope
        if let ancestor = AXDebug.findBestAncestor(of: element) {
            // Find scope element and search within
            let scopeMatches = TargetResolver.findAll(in: root, matching: ancestor)
            if let scopeElement = scopeMatches.first?.element {
                let scopedResults = TargetResolver.findAll(
                    in: root, matching: selector,
                    scope: scopeElement, requiredRole: nil
                )
                if scopedResults.count == 1 {
                    return ResolvedAction(
                        command: command,
                        selector: selector,
                        role: roleShort, within: ancestor, occurrence: nil,
                        identifier: usedIdentifier ? attrs.identifier : nil,
                        fragile: false,
                        coordinate: point
                    )
                }
            }
        }

        // 5c. Fallback: label[N] occurrence
        let occurrence = findOccurrence(of: element, in: allMatches)
        return ResolvedAction(
            command: command,
            selector: occurrence != nil ? "\(selector)[\(occurrence!)]" : selector,
            role: roleShort, within: nil,
            occurrence: occurrence,
            identifier: usedIdentifier ? attrs.identifier : nil,
            fragile: true,
            coordinate: point
        )
    }

    // MARK: - Private Helpers

    internal struct ElementAttributes {
        let role: String?
        let title: String?
        let label: String?       // AXDescription
        let identifier: String?
        let value: String?
    }

    /// Manual hit-test walking the AX tree, checking frame containment.
    /// This is more reliable than AXUIElementCopyElementAtPosition for Simulator windows.
    private static func hitTest(at point: CGPoint, root: AXUIElement) -> AXUIElement? {
        return hitTestRecursive(at: point, element: root, depth: 0)
    }

    private static func hitTestRecursive(at point: CGPoint, element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth < 20 else { return nil }

        var childrenRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef)
        guard let children = childrenRef as? [AXUIElement] else { return nil }

        var best: AXUIElement?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for child in children {
            // Get position
            var posRef: CFTypeRef?
            let posResult = AXUIElementCopyAttributeValue(child, kAXPositionAttribute as CFString, &posRef)
            guard posResult == .success, posRef != nil else { continue }
            var pos = CGPoint.zero
            guard AXValueGetValue(posRef as! AXValue, .cgPoint, &pos) else { continue }

            // Get size
            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXSizeAttribute as CFString, &sizeRef)
            guard let sizeRef else { continue }
            var size = CGSize.zero
            guard AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { continue }

            let frame = CGRect(origin: pos, size: size)
            if frame.contains(point) {
                let area = size.width * size.height
                if area < bestArea {
                    bestArea = area
                    best = child
                }
                // Recurse deeper — prefer the deepest (smallest) match
                if let deeper = hitTestRecursive(at: point, element: child, depth: depth + 1) {
                    return deeper
                }
            }
        }

        return best
    }

    private static func extractAttributes(_ element: AXUIElement) -> ElementAttributes {
        func getString(_ attr: String) -> String? {
            var ref: CFTypeRef?
            AXUIElementCopyAttributeValue(element, attr as CFString, &ref)
            let s = ref as? String
            return (s?.isEmpty == true) ? nil : s
        }

        return ElementAttributes(
            role: getString(kAXRoleAttribute as String),
            title: getString(kAXTitleAttribute as String),
            label: getString(kAXDescriptionAttribute as String),
            identifier: getString(kAXIdentifierAttribute as String),
            value: getString(kAXValueAttribute as String)
        )
    }

    /// Choose the best selector string. Returns (selector, usedIdentifier).
    ///
    /// Priority: identifier > title > label > value.
    ///
    /// The `value` fallback is skipped for text inputs. The value of an
    /// AXTextField is whatever the user has typed — e.g. during recording
    /// the email field may hold `"success+714497402@..."`. Emitting that
    /// as a selector produces a `waitFor "success+..."` in the generated
    /// script that never matches on replay (the field starts empty). This
    /// was the P0 bug documented in `recorder_experiment_findings.md`.
    internal static func chooseBestSelector(_ attrs: ElementAttributes) -> (String?, Bool) {
        if let id = attrs.identifier, isStableIdentifier(id) {
            return (id, true)
        }

        if let title = attrs.title {
            return (title, false)
        }

        if let label = attrs.label {
            return (label, false)
        }

        if let value = attrs.value, value.count < 50, !isTextInputRole(attrs.role) {
            return (value, false)
        }

        return (nil, false)
    }

    private static func isTextInputRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return role == "AXTextField" || role == "AXSecureTextField" || role == "AXTextArea"
    }

    /// Check if an identifier looks stable (not auto-generated UUID or random hash).
    private static func isStableIdentifier(_ id: String) -> Bool {
        // Skip identifiers that look like UUIDs or auto-generated
        if id.count > 40 { return false }
        // Skip pure hex strings (likely auto-generated)
        let hexChars = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
        if id.unicodeScalars.allSatisfy({ hexChars.contains($0) }) && id.count > 20 {
            return false
        }
        return true
    }

    /// Convert AX role to short form: "AXButton" → "button"
    private static func shortRole(_ role: String?) -> String? {
        guard let role, role.hasPrefix("AX") else { return role?.lowercased() }
        let short = String(role.dropFirst(2)).lowercased()
        // Only emit role for actionable element types
        let actionableRoles = ["button", "textfield", "checkbox", "radiobutton",
                               "popupbutton", "slider", "link", "menuitem",
                               "tab", "cell", "switch", "toggle",
                               "segmentedcontrol", "picker", "stepper"]
        return actionableRoles.contains(short) ? short : nil
    }

    /// Find which occurrence index this element is among the matches.
    private static func findOccurrence(
        of target: AXUIElement,
        in matches: [(element: AXUIElement, occurrence: Int)]
    ) -> Int? {
        for (element, occurrence) in matches {
            if CFEqual(target, element) {
                return occurrence
            }
        }
        // If CFEqual doesn't work (different AXUIElement refs to same element),
        // fall back to position comparison
        var targetPos: CFTypeRef?
        AXUIElementCopyAttributeValue(target, kAXPositionAttribute as CFString, &targetPos)
        guard let targetPoint = targetPos else { return matches.first?.occurrence }

        var tpVal = CGPoint.zero
        if !AXValueGetValue(targetPoint as! AXValue, .cgPoint, &tpVal) {
            return matches.first?.occurrence
        }

        for (element, occurrence) in matches {
            var elemPos: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &elemPos)
            if let elemPos {
                var epVal = CGPoint.zero
                if AXValueGetValue(elemPos as! AXValue, .cgPoint, &epVal) {
                    if abs(tpVal.x - epVal.x) < 2 && abs(tpVal.y - epVal.y) < 2 {
                        return occurrence
                    }
                }
            }
        }

        return matches.first?.occurrence
    }
}
