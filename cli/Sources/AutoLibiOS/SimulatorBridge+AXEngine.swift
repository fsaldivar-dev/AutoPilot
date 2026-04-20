import Foundation
import ApplicationServices
import AppKit
import AutoCore

// MARK: - AXEngine
//
// AX macOS queries + element search + serialization iOS. Extraído de
// `SimulatorBridge.swift` — la API pública del bridge no cambia, el código
// solo vive en este archivo separado.
//
// Responsabilidades:
//   - `findSimulator` / `findSimulatorPID` / `findSimulatorContent` / Fast
//   - `tree` / `search` / `elementAt` / `existsFast`
//   - `findAXElement` / `findAXElementExact` / `findAXElementContains`
//   - `findAXElementScoped` (con role + within fallbacks)
//   - `tapElement`
//   - Serialización (`serializeElement`, `serializeChildren`, `searchRecursive`)
//   - Helpers AX (`getAttribute`, `getChildren`, `getPosition`, `getSize`,
//     `getParent`, `getRole`, `getFirstWindow`)
//
// Los helpers privados (`getAttribute`, `getChildren`, etc.) son accedidos
// por otras extensions del mismo bridge (gestures, input) — por eso son
// `internal` (sin prefijo), no `private`.

extension SimulatorBridge {

    // MARK: - Find Simulator

    /// Finds the running Simulator.app process.
    public func findSimulator() throws -> AXUIElement {
        let workspace = NSWorkspace.shared
        guard let simApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else {
            throw BridgeError.simulatorNotRunning
        }

        simulatorPID = simApp.processIdentifier
        return AXUIElementCreateApplication(simApp.processIdentifier)
    }

    public func findSimulatorPID() -> pid_t? {
        let workspace = NSWorkspace.shared
        guard let simApp = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else { return nil }
        simulatorPID = simApp.processIdentifier
        return simApp.processIdentifier
    }

    public func findSimulatorContent() throws -> AXUIElement {
        // Fast path: if we already have the PID cached and the AX window is
        // ready, read it directly without activating. Preserves caller focus
        // (editor, terminal). Activation is only needed as a fallback when
        // the Simulator just booted and its AX tree isn't hydrated yet.
        if let pid = simulatorPID {
            let app = AXUIElementCreateApplication(pid)
            if let window = getFirstWindow(of: app),
               let children = getChildren(of: window),
               !children.isEmpty {
                return window
            }
        }

        // Slow path: re-discover PID and activate to force AX hydration.
        let workspace = NSWorkspace.shared
        guard let simRunning = workspace.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.iphonesimulator"
        }) else {
            throw BridgeError.simulatorNotRunning
        }

        simulatorPID = simRunning.processIdentifier

        let app = AXUIElementCreateApplication(simRunning.processIdentifier)

        // Try without activating first — maybe the tree is already live
        // after a PID refresh.
        if let window = getFirstWindow(of: app),
           let children = getChildren(of: window),
           !children.isEmpty {
            return window
        }

        // Last resort: activate to force AX tree hydration.
        simRunning.activate(options: .activateIgnoringOtherApps)

        for _ in 0..<15 {
            if let window = getFirstWindow(of: app),
               let children = getChildren(of: window),
               !children.isEmpty {
                return window
            }
            usleep(200_000)
        }

        if !AXIsProcessTrusted() {
            throw BridgeError.accessibilityNotTrusted
        }
        throw BridgeError.noWindow
    }

    /// Lightweight content access — skips activation and retries.
    /// Use during recording when Simulator is already in the foreground.
    /// Get the Simulator window frame in screen coordinates.
    public func getSimulatorWindowFrame() -> CGRect? {
        guard let window = findSimulatorContentFast() else { return nil }
        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        guard let posRef, let sizeRef else { return nil }
        var pos = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    public func findSimulatorContentFast() -> AXUIElement? {
        guard let pid = simulatorPID else { return nil }
        let app = AXUIElementCreateApplication(pid)
        return getFirstWindow(of: app)
    }

    // MARK: - Tree / Search / ElementAt / ExistsFast

    /// Returns the full accessibility tree of the frontmost simulator window.
    public func tree(element: AXUIElement? = nil) throws -> [[String: Any]] {
        let root = try element.map { $0 } ?? findSimulatorContent()
        return serializeChildren(of: root, depth: 0, maxDepth: 20)
    }

    /// Searches elements matching a query.
    public func search(query: String) throws -> [[String: Any]] {
        let root = try findSimulatorContent()
        var results: [[String: Any]] = []
        searchRecursive(element: root, query: query.lowercased(), results: &results, depth: 0, maxDepth: 20)
        return results
    }

    /// Finds the element at a screen coordinate (relative to simulator content).
    public func elementAt(x: Double, y: Double) throws -> [String: Any]? {
        let root = try findSimulatorContent()
        let point = CGPoint(x: x, y: y)
        return findElementAt(point: point, in: root, depth: 0)
    }

    /// Shallow existence check por label/title/identifier. Early-exit en primer
    /// match, sin serializar atributos extra. Usado por `waitFor`/`waitUntilGone`.
    /// ~5-10ms vs ~30-50ms de `search()`.
    public func existsFast(label: String) throws -> Bool {
        let root = try findSimulatorContent()
        return findAXElement(in: root, matching: label, depth: 0, maxDepth: 12) != nil
    }

    // MARK: - Element lookup (by target string)

    /// Finds the raw AXUIElement matching target (for performing actions).
    /// Priority: exact match (all depths) → contains match (all depths)
    func findAXElement(in element: AXUIElement, matching target: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        let lowered = target.lowercased()

        // 1. Exact match at this level
        for child in children {
            let title = (getAttribute(child, kAXTitleAttribute) as? String ?? "").lowercased()
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            let identifier = (getAttribute(child, "AXIdentifier") as? String ?? "").lowercased()
            let value = (getAttribute(child, kAXValueAttribute) as? String ?? "").lowercased()

            if identifier == lowered || title == lowered || label == lowered || value == lowered {
                return child
            }
        }

        // 2. Recurse for exact match at deeper levels BEFORE contains match
        for child in children {
            if let found = findAXElementExact(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }

        // 3. Contains match — only on label (description), prefer shorter (more specific)
        var containsMatch: (element: AXUIElement, length: Int)?
        for child in children {
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            if !label.isEmpty && label.contains(lowered) {
                let len = label.count
                if containsMatch == nil || len < containsMatch!.length {
                    containsMatch = (child, len)
                }
            }
        }
        if let match = containsMatch {
            return match.element
        }

        // 4. Recurse for contains match at deeper levels
        for child in children {
            if let found = findAXElementContains(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }

        return nil
    }

    /// Exact-only recursive search (used as priority pass).
    private func findAXElementExact(in element: AXUIElement, matching lowered: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        for child in children {
            let title = (getAttribute(child, kAXTitleAttribute) as? String ?? "").lowercased()
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            let identifier = (getAttribute(child, "AXIdentifier") as? String ?? "").lowercased()
            let value = (getAttribute(child, kAXValueAttribute) as? String ?? "").lowercased()

            if identifier == lowered || title == lowered || label == lowered || value == lowered {
                return child
            }
        }

        for child in children {
            if let found = findAXElementExact(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Contains-only recursive search (used as fallback pass).
    private func findAXElementContains(in element: AXUIElement, matching lowered: String, depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        var best: (element: AXUIElement, length: Int)?
        for child in children {
            let label = (getAttribute(child, kAXDescriptionAttribute) as? String ?? "").lowercased()
            if !label.isEmpty && label.contains(lowered) {
                let len = label.count
                if best == nil || len < best!.length {
                    best = (child, len)
                }
            }
        }
        if let match = best {
            return match.element
        }

        for child in children {
            if let found = findAXElementContains(in: child, matching: lowered, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Like `findAXElement` but returns a serialized dict (for public API).
    func findElementInfo(in element: AXUIElement, matching target: String, depth: Int, maxDepth: Int) -> [String: Any]? {
        guard depth < maxDepth else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        let lowered = target.lowercased()

        // First pass: exact match on any field
        for child in children {
            let info = serializeElement(child)
            let title = (info["title"] as? String ?? "").lowercased()
            let label = (info["label"] as? String ?? "").lowercased()
            let identifier = (info["identifier"] as? String ?? "").lowercased()
            let value = (info["value"] as? String ?? "").lowercased()

            if identifier == lowered || title == lowered || label == lowered || value == lowered {
                return info
            }
        }

        // Second pass: partial match (description often has long text like "General, ...")
        for child in children {
            let info = serializeElement(child)
            let label = (info["label"] as? String ?? "").lowercased()

            if label.hasPrefix(lowered) || label.contains(", \(lowered)") {
                return info
            }
        }

        // Recurse into children
        for child in children {
            if let found = findElementInfo(in: child, matching: target, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Finds the smallest element containing a point (hit-test).
    private func findElementAt(point: CGPoint, in element: AXUIElement, depth: Int) -> [String: Any]? {
        guard depth < 20 else { return nil }
        guard let children = getChildren(of: element) else { return nil }

        var best: [String: Any]?
        var bestArea: CGFloat = .greatestFiniteMagnitude

        for child in children {
            guard let pos = getPosition(of: child), let size = getSize(of: child) else { continue }
            let frame = CGRect(origin: pos, size: size)

            if frame.contains(point) {
                let area = size.width * size.height
                if area < bestArea {
                    bestArea = area
                    var info = serializeElement(child)
                    info.removeValue(forKey: "_position")
                    info.removeValue(forKey: "_size")
                    best = info
                }
                if let deeper = findElementAt(point: point, in: child, depth: depth + 1) {
                    return deeper
                }
            }
        }
        return best
    }

    // MARK: - Tap raw element

    /// Tap a resolved AXUIElement directly (AXPress with click fallback).
    public func tapElement(_ element: AXUIElement) {
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        if result != .success {
            if let pos = getPosition(of: element), let size = getSize(of: element) {
                let center = CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
                try? click(at: center)
            }
        }
    }

    // MARK: - Scoped element search (role + within + label[N])

    /// Find element with optional role filtering and scope.
    /// Fallback chain: role+scope → scope only → global → error
    public func findAXElementScoped(target: String, role: String? = nil, within: String? = nil) throws -> AXUIElement {
        let root = try findSimulatorContent()

        // Resolve scope element
        var scopeElement: AXUIElement? = nil
        if let within {
            scopeElement = findAXElement(in: root, matching: within, depth: 0, maxDepth: 20)
            if scopeElement == nil {
                fputs("[within] '\(within)' not found, searching globally\n", stderr)
            }
        }

        // Parse label[N] from target
        let (label, occurrence) = TargetResolver.parse(target)

        // Search with role + scope
        let matches = TargetResolver.findAll(in: root, matching: label, scope: scopeElement, requiredRole: role)

        if let occurrence {
            if occurrence >= 1 && occurrence <= matches.count {
                return matches[occurrence - 1].element
            }
            // Fallback: without role
            if role != nil {
                fputs("[role] no \(role!) matching '\(label)[\(occurrence)]', trying without role\n", stderr)
                let fallback = TargetResolver.findAll(in: root, matching: label, scope: scopeElement, requiredRole: nil)
                if occurrence >= 1 && occurrence <= fallback.count {
                    return fallback[occurrence - 1].element
                }
            }
            // Fallback: without scope
            if scopeElement != nil {
                fputs("[within] '\(label)[\(occurrence)]' not found in '\(within!)', searching globally\n", stderr)
                let global = TargetResolver.findAll(in: root, matching: label, scope: nil, requiredRole: nil)
                if occurrence >= 1 && occurrence <= global.count {
                    return global[occurrence - 1].element
                }
            }
            throw BridgeError.elementNotFound(target)
        }

        // No occurrence specified — return first match
        if let first = matches.first {
            return first.element
        }

        // Fallback: without role
        if role != nil {
            fputs("[role] no \(role!) matching '\(label)', trying without role filter\n", stderr)
            let fallback = TargetResolver.findAll(in: root, matching: label, scope: scopeElement, requiredRole: nil)
            if let first = fallback.first { return first.element }
        }

        // Fallback: without scope
        if scopeElement != nil {
            fputs("[within] '\(label)' not found in '\(within!)', searching globally\n", stderr)
            let global = TargetResolver.findAll(in: root, matching: label, scope: nil, requiredRole: nil)
            if let first = global.first { return first.element }
        }

        throw BridgeError.elementNotFound(target)
    }

    // MARK: - Public AX helpers

    /// Get parent of an AX element.
    public func getParent(of element: AXUIElement) -> AXUIElement? {
        getAttribute(element, kAXParentAttribute) as! AXUIElement?
    }

    /// Get role of an AX element.
    public func getRole(of element: AXUIElement) -> String? {
        getAttribute(element, kAXRoleAttribute) as? String
    }

    // MARK: - Serialization

    /// Convert an AXUIElement to a dict with role/title/label/value/frame/enabled.
    /// Internal keys `_position` and `_size` are used by callers that need
    /// the raw CGPoint/CGSize — they are stripped from public output.
    func serializeElement(_ element: AXUIElement) -> [String: Any] {
        var dict: [String: Any] = [:]

        dict["role"] = getAttribute(element, kAXRoleAttribute) as? String ?? "Unknown"
        dict["title"] = getAttribute(element, kAXTitleAttribute) as? String ?? ""
        dict["value"] = getAttribute(element, kAXValueAttribute) as? String ?? ""
        dict["label"] = getAttribute(element, kAXDescriptionAttribute) as? String ?? ""
        dict["identifier"] = getAttribute(element, "AXIdentifier") as? String ?? ""

        if let pos = getPosition(of: element), let size = getSize(of: element) {
            dict["frame"] = [
                "x": Int(pos.x), "y": Int(pos.y),
                "width": Int(size.width), "height": Int(size.height)
            ]
            dict["_position"] = pos
            dict["_size"] = size
        }

        let enabled = getAttribute(element, kAXEnabledAttribute) as? Bool ?? true
        dict["enabled"] = enabled

        return dict
    }

    private func serializeChildren(of element: AXUIElement, depth: Int, maxDepth: Int) -> [[String: Any]] {
        guard depth < maxDepth else { return [] }

        var result: [[String: Any]] = []
        guard let children = getChildren(of: element) else { return [] }

        for child in children {
            let info = serializeElement(child)
            // Remove internal keys
            var clean = info
            clean.removeValue(forKey: "_position")
            clean.removeValue(forKey: "_size")

            let childElements = serializeChildren(of: child, depth: depth + 1, maxDepth: maxDepth)
            if !childElements.isEmpty {
                clean["children"] = childElements
            }
            result.append(clean)
        }
        return result
    }

    private func searchRecursive(element: AXUIElement, query: String, results: inout [[String: Any]], depth: Int, maxDepth: Int) {
        guard depth < maxDepth else { return }
        guard let children = getChildren(of: element) else { return }

        for child in children {
            let info = serializeElement(child)
            let role = (info["role"] as? String ?? "").lowercased()
            let title = (info["title"] as? String ?? "").lowercased()
            let label = (info["label"] as? String ?? "").lowercased()
            let identifier = (info["identifier"] as? String ?? "").lowercased()
            let value = (info["value"] as? String ?? "").lowercased()

            if role.contains(query) || title.contains(query) || label.contains(query)
                || identifier.contains(query) || value.contains(query) {
                var clean = info
                clean.removeValue(forKey: "_position")
                clean.removeValue(forKey: "_size")
                results.append(clean)
            }

            searchRecursive(element: child, query: query, results: &results, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    // MARK: - Private AX primitives (internal — usados por gestures extensions)

    func getAttribute(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        return value
    }

    func getChildren(of element: AXUIElement) -> [AXUIElement]? {
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        return children as? [AXUIElement]
    }

    func getFirstWindow(of app: AXUIElement) -> AXUIElement? {
        var windows: CFTypeRef?
        AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard let windowArray = windows as? [AXUIElement], let first = windowArray.first else {
            return nil
        }
        return first
    }

    func getPosition(of element: AXUIElement) -> CGPoint? {
        var posValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posValue)
        guard let val = posValue else { return nil }
        var point = CGPoint.zero
        AXValueGetValue(val as! AXValue, .cgPoint, &point)
        return point
    }

    func getSize(of element: AXUIElement) -> CGSize? {
        var sizeValue: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue)
        guard let val = sizeValue else { return nil }
        var size = CGSize.zero
        AXValueGetValue(val as! AXValue, .cgSize, &size)
        return size
    }
}
