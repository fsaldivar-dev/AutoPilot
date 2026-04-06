import Foundation

/// Resolves a screen coordinate to a semantic selector using the Android AX tree (JSON).
/// Uses the same resolution strategy as iOS SemanticResolver but works with
/// dictionary-based tree from AgentBridge instead of AXUIElement.
public struct AndroidSemanticResolver {

    /// Resolve a touch at screen coordinate to a semantic action.
    public static func resolveTouch(
        x: Int, y: Int,
        tree: [[String: Any]],
        command: String = "tap"
    ) -> ResolvedAction {
        let point = CGPoint(x: CGFloat(x), y: CGFloat(y))

        // 1. Hit-test: find deepest element at coordinate
        guard let element = hitTest(x: x, y: y, in: tree) else {
            return ResolvedAction(
                command: "tapAt",
                selector: "\(x) \(y)",
                role: nil, within: nil, occurrence: nil,
                identifier: nil, fragile: true, coordinate: point
            )
        }

        // 2. Extract attributes
        let role = element["role"] as? String
        let title = nonEmpty(element["title"] as? String)
        let label = nonEmpty(element["label"] as? String)
        let identifier = nonEmpty(element["identifier"] as? String)
        let value = nonEmpty(element["value"] as? String)

        // 3. Choose best selector
        let (selector, usedIdentifier) = chooseBestSelector(
            identifier: identifier, title: title, label: label, value: value
        )

        guard let selector else {
            return ResolvedAction(
                command: "tapAt",
                selector: "\(x) \(y)",
                role: nil, within: nil, occurrence: nil,
                identifier: identifier, fragile: true, coordinate: point
            )
        }

        // 4. Check uniqueness in tree
        let allMatches = TargetResolverShared.findAll(in: tree, matching: selector)

        if allMatches.count <= 1 {
            return ResolvedAction(
                command: command,
                selector: selector,
                role: nil, within: nil, occurrence: nil,
                identifier: usedIdentifier ? identifier : nil,
                fragile: !usedIdentifier,
                coordinate: point
            )
        }

        // 5. Multiple matches — disambiguate

        // 5a. Try role filter
        let roleShort = shortRole(role)
        if let roleShort {
            let roleMatches = TargetResolverShared.findAll(
                in: tree, matching: selector, requiredRole: roleShort
            )
            if roleMatches.count == 1 {
                return ResolvedAction(
                    command: command,
                    selector: selector,
                    role: roleShort, within: nil, occurrence: nil,
                    identifier: usedIdentifier ? identifier : nil,
                    fragile: false,
                    coordinate: point
                )
            }
        }

        // 5b. Try within scope — walk parent chain in tree
        // Skip generic root containers (android:id/content, etc.)
        if let ancestor = findBestAncestor(of: element, in: tree),
           !isGenericContainer(ancestor) {
            return ResolvedAction(
                command: command,
                selector: selector,
                role: roleShort, within: ancestor, occurrence: nil,
                identifier: usedIdentifier ? identifier : nil,
                fragile: false,
                coordinate: point
            )
        }

        // 5c. Fallback: label[N] occurrence
        let occurrence = findOccurrence(x: x, y: y, in: allMatches)
        return ResolvedAction(
            command: command,
            selector: occurrence != nil ? "\(selector)[\(occurrence!)]" : selector,
            role: roleShort, within: nil,
            occurrence: occurrence,
            identifier: usedIdentifier ? identifier : nil,
            fragile: true,
            coordinate: point
        )
    }

    // MARK: - Hit Test

    /// Find the best element at the given point.
    /// Prefers the deepest element WITH text/label. If the deepest has no text,
    /// searches siblings and ancestors for the nearest labeled element.
    private static func hitTest(x: Int, y: Int, in elements: [[String: Any]]) -> [String: Any]? {
        let hit = hitTestDeepest(x: x, y: y, in: elements)
        guard let hit else { return nil }

        // If the deepest hit has a usable label, use it
        if hasLabel(hit) { return hit }

        // Otherwise, search nearby: find the closest labeled element
        // that overlaps or is very close to the touch point
        if let labeled = findNearestLabeled(x: x, y: y, in: elements, maxDistance: 80) {
            return labeled
        }

        return hit
    }

    /// Find the deepest (smallest area) element containing the point.
    private static func hitTestDeepest(x: Int, y: Int, in elements: [[String: Any]]) -> [String: Any]? {
        var best: [String: Any]?
        var bestArea = Int.max

        for element in elements {
            if let frame = element["frame"] as? [String: Any],
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                if x >= fx && x <= fx + fw && y >= fy && y <= fy + fh {
                    let area = fw * fh
                    if area < bestArea && area > 0 {
                        bestArea = area
                        best = element
                    }
                    if let children = element["children"] as? [[String: Any]] {
                        if let deeper = hitTestDeepest(x: x, y: y, in: children) {
                            return deeper
                        }
                    }
                }
            }
        }

        return best
    }

    /// Find the nearest element with a label within maxDistance of the point.
    private static func findNearestLabeled(x: Int, y: Int, in elements: [[String: Any]], maxDistance: Int) -> [String: Any]? {
        var best: [String: Any]?
        var bestDist = Double(maxDistance)

        findNearestLabeledRecursive(x: x, y: y, in: elements, bestDist: &bestDist, best: &best)
        return best
    }

    private static func findNearestLabeledRecursive(
        x: Int, y: Int,
        in elements: [[String: Any]],
        bestDist: inout Double,
        best: inout [String: Any]?
    ) {
        for element in elements {
            if hasLabel(element),
               let frame = element["frame"] as? [String: Any],
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let cx = fx + fw / 2
                let cy = fy + fh / 2
                let dist = sqrt(Double((x - cx) * (x - cx) + (y - cy) * (y - cy)))
                if dist < bestDist {
                    bestDist = dist
                    best = element
                }
            }
            if let children = element["children"] as? [[String: Any]] {
                findNearestLabeledRecursive(x: x, y: y, in: children, bestDist: &bestDist, best: &best)
            }
        }
    }

    /// Check if an element has any usable text label.
    private static func hasLabel(_ element: [String: Any]) -> Bool {
        nonEmpty(element["title"] as? String) != nil ||
        nonEmpty(element["label"] as? String) != nil ||
        nonEmpty(element["identifier"] as? String) != nil
    }

    // MARK: - Selector Strategy

    private static func chooseBestSelector(
        identifier: String?, title: String?, label: String?, value: String?
    ) -> (String?, Bool) {
        // Priority 1: identifier (if stable)
        if let id = identifier, isStableIdentifier(id) {
            return (id, true)
        }
        // Priority 2: title (text content)
        if let title { return (title, false) }
        // Priority 3: label (contentDescription)
        if let label { return (label, false) }
        // Priority 4: value (if short)
        if let value, value.count < 50 { return (value, false) }
        return (nil, false)
    }

    private static func isStableIdentifier(_ id: String) -> Bool {
        if id.count > 60 { return false }
        // Skip auto-generated resource IDs that are just numbers
        if Int(id) != nil { return false }
        return true
    }

    /// Convert Android class name to short role: "android.widget.Button" → "button"
    private static func shortRole(_ role: String?) -> String? {
        guard let role else { return nil }
        // Android roles come as "Button", "TextView", etc. (already stripped by TreeSerializer)
        let lower = role.lowercased()
        let actionable = ["button", "edittext", "checkbox", "radiobutton",
                          "switch", "togglebutton", "imagebutton", "spinner",
                          "seekbar", "ratingbar", "tabwidget", "listview",
                          "recyclerview", "scrollview"]
        return actionable.contains(lower) ? lower : nil
    }

    // MARK: - Ancestor / Within

    /// Walk the tree to find a meaningful ancestor for a `within` clause.
    /// Returns the identifier or label of the best ancestor container.
    private static func findBestAncestor(of target: [String: Any], in tree: [[String: Any]]) -> String? {
        // Build path from root to target
        var path: [[String: Any]] = []
        if findPath(to: target, in: tree, path: &path) {
            // Walk path in reverse (nearest ancestors first)
            for ancestor in path.reversed() {
                let id = nonEmpty(ancestor["identifier"] as? String)
                let title = nonEmpty(ancestor["title"] as? String)
                let label = nonEmpty(ancestor["label"] as? String)

                let ancestorLabel = id ?? title ?? label
                if let ancestorLabel, ancestorLabel != (target["title"] as? String) {
                    return ancestorLabel
                }
            }
        }
        return nil
    }

    /// Find the path from root to a target element in the tree.
    private static func findPath(
        to target: [String: Any],
        in elements: [[String: Any]],
        path: inout [[String: Any]]
    ) -> Bool {
        for element in elements {
            // Check if this is the target (compare by frame position)
            if elementsMatch(element, target) {
                return true
            }
            if let children = element["children"] as? [[String: Any]] {
                path.append(element)
                if findPath(to: target, in: children, path: &path) {
                    return true
                }
                path.removeLast()
            }
        }
        return false
    }

    /// Compare two elements by frame position (since we don't have object identity).
    private static func elementsMatch(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard let fa = a["frame"] as? [String: Any],
              let fb = b["frame"] as? [String: Any] else { return false }
        return (fa["x"] as? Int) == (fb["x"] as? Int) &&
               (fa["y"] as? Int) == (fb["y"] as? Int) &&
               (fa["width"] as? Int) == (fb["width"] as? Int) &&
               (fa["height"] as? Int) == (fb["height"] as? Int)
    }

    // MARK: - Occurrence

    /// Find which occurrence this element is among matches (by closest frame).
    private static func findOccurrence(x: Int, y: Int, in matches: [(element: [String: Any], occurrence: Int)]) -> Int? {
        var bestDist = Double.greatestFiniteMagnitude
        var bestOcc: Int?

        for (element, occurrence) in matches {
            if let frame = element["frame"] as? [String: Any],
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let cx = fx + fw / 2
                let cy = fy + fh / 2
                let dist = sqrt(Double((x - cx) * (x - cx) + (y - cy) * (y - cy)))
                if dist < bestDist {
                    bestDist = dist
                    bestOcc = occurrence
                }
            }
        }
        return bestOcc
    }

    // MARK: - Helpers

    /// Check if an ancestor label is too generic to be useful as a `within` scope.
    private static func isGenericContainer(_ label: String) -> Bool {
        let generic = ["android:id/content", "android:id/decor_content_parent",
                       "android:id/action_bar_overlay_layout", "content",
                       "android:id/statusBarBackground", "android:id/navigationBarBackground"]
        return generic.contains(label) || label.hasPrefix("android:id/")
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
