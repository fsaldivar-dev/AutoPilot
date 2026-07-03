import Foundation
import XCTest

// MARK: - RunnerHandlers
//
// Maps JSON commands to XCUIApplication/XCUIElement actions.
// Each handler receives params dict, returns JSON string response.

final class RunnerHandlers {
    let app: XCUIApplication
    /// The currently active app (set by launch, defaults to initial app).
    var activeApp: XCUIApplication
    /// Bundle id of the currently active app (if set by launch).
    private var activeBundleId: String?

    init(app: XCUIApplication) {
        self.app = app
        self.activeApp = app
    }

    /// The app to query for elements.
    ///
    /// Resolution strategy:
    ///   1. If params contain `bundleId`, use it (creates fresh XCUIApplication
    ///      to ensure sync with newly-launched/re-launched apps).
    ///   2. If activeApp's process is in foreground, use it.
    ///   3. Otherwise, if activeBundleId is set, rebuild a fresh XCUIApplication
    ///      from it to recover from external terminate/launch cycles.
    ///   4. Fallback: the initial app.
    private func resolveApp(params: [String: Any]) -> XCUIApplication {
        if let bid = params["bundleId"] as? String, !bid.isEmpty {
            let a = XCUIApplication(bundleIdentifier: bid)
            activeApp = a
            activeBundleId = bid
            return a
        }

        // Check whether the current activeApp is still running and responsive.
        // XCUIApplication.state == .runningForeground is the canonical check.
        if activeApp.state == .runningForeground {
            return activeApp
        }

        // activeApp is stale (was terminated externally). Try to rebuild it
        // from the bundle id we saw on the last launch.
        if let bid = activeBundleId {
            let a = XCUIApplication(bundleIdentifier: bid)
            activeApp = a
            return a
        }

        return activeApp
    }

    /// Backwards-compatible accessor for handlers that don't pass params.
    private var currentApp: XCUIApplication {
        resolveApp(params: [:])
    }

    // MARK: - Tree / Search

    func handleTree(params: [String: Any]) -> String {
        let app = resolveApp(params: params)
        // Force the app to refresh its element hierarchy
        _ = app.descendants(matching: .any).count
        let snapshot = serializeElement(app)
        return successJSON(["tree": snapshot])
    }

    func handleSearch(params: [String: Any]) -> String {
        guard let query = params["query"] as? String else {
            return errorJSON("missing 'query' param")
        }
        let app = resolveApp(params: params)

        let predicate = NSPredicate(format:
            "label CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@ OR value CONTAINS[cd] %@",
            query, query, query)
        let matches = app.descendants(matching: .any).matching(predicate)
        var results: [[String: Any]] = []

        for i in 0..<min(matches.count, 50) {
            let el = matches.element(boundBy: i)
            if el.exists {
                results.append(serializeSingleElement(el))
            }
        }

        return successJSON(["matches": results, "count": results.count])
    }

    // MARK: - List (fast, typed query)
    //
    // Returns a flat array of elements of the requested type(s). Much faster
    // than handleTree because XCTest only materializes the typed query — no
    // recursive descent, no attribute-by-attribute XPC for every node.
    //
    // Type values:
    //   "buttons", "labels"/"statictexts", "textfields", "cells", "switches",
    //   "links", "images", "all" (buttons+fields+cells+switches+links)
    //
    // Each item: {role, label, identifier, value, frame, enabled}.
    func handleList(params: [String: Any]) -> String {
        let type = (params["type"] as? String ?? "all").lowercased()
        let app = resolveApp(params: params)

        var queries: [(String, XCUIElementQuery)] = []
        switch type {
        case "buttons":          queries = [("Button", app.buttons)]
        case "labels", "statictexts":
                                 queries = [("StaticText", app.staticTexts)]
        case "textfields":       queries = [("TextField", app.textFields),
                                            ("SecureTextField", app.secureTextFields),
                                            // iOS search fields (UISearchTextField) son
                                            // .searchField en XCUI, no .textField — sin esta
                                            // query `list textfields` no ve search bars que el
                                            // AX tree sí reporta como AXTextField (issue #134).
                                            ("SearchField", app.searchFields),
                                            // Paridad con el fast path del observer, que cuenta
                                            // AXTextArea (UITextView) como textfield.
                                            ("TextView", app.textViews)]
        case "cells":            queries = [("Cell", app.cells)]
        case "switches":         queries = [("Switch", app.switches)]
        case "links":            queries = [("Link", app.links)]
        case "images":           queries = [("Image", app.images)]
        case "navbars", "navigationbars":
                                 queries = [("NavigationBar", app.navigationBars)]
        case "all", "":
            // Everything commonly interactive — excludes Image/StaticText to
            // keep the list focused on "things you can interact with".
            queries = [
                ("Button", app.buttons),
                ("TextField", app.textFields),
                ("SecureTextField", app.secureTextFields),
                ("SearchField", app.searchFields),
                ("Cell", app.cells),
                ("Switch", app.switches),
                ("Link", app.links),
            ]
        default:
            return errorJSON("unknown list type: \(type). Valid: buttons|labels|textfields|cells|switches|links|images|navbars|all")
        }

        var items: [[String: Any]] = []
        let maxPerType = 200 // safety cap

        for (roleName, q) in queries {
            let count = q.count
            let n = min(count, maxPerType)
            for i in 0..<n {
                let el = q.element(boundBy: i)
                if !el.exists { continue }
                // Use snapshot() for batched attribute fetch — ONE XPC per element
                // instead of 7 separate attribute reads.
                do {
                    let snap = try el.snapshot()
                    var dict: [String: Any] = ["role": roleName]
                    if !snap.label.isEmpty { dict["label"] = snap.label }
                    if !snap.identifier.isEmpty { dict["identifier"] = snap.identifier }
                    if let v = snap.value, let s = v as? String, !s.isEmpty { dict["value"] = s }
                    if snap.frame != .zero {
                        dict["frame"] = [
                            "x": Int(snap.frame.origin.x),
                            "y": Int(snap.frame.origin.y),
                            "width": Int(snap.frame.size.width),
                            "height": Int(snap.frame.size.height)
                        ]
                    }
                    dict["enabled"] = snap.isEnabled
                    items.append(dict)
                } catch {
                    // Skip elements that can't be snapshotted (stale refs, etc)
                    continue
                }
            }
        }

        return successJSON(["items": items, "count": items.count, "type": type])
    }

    func handleExists(params: [String: Any]) -> String {
        guard let target = params["target"] as? String else {
            return errorJSON("missing 'target' param")
        }

        let element = findElement(target: target, params: params)
        return successJSON(["exists": element?.exists ?? false])
    }

    // MARK: - Tap

    func handleTap(params: [String: Any]) -> String {
        guard let target = params["target"] as? String else {
            return errorJSON("missing 'target' param")
        }

        guard let element = findElement(target: target, params: params), element.exists else {
            return errorJSON("element not found: \(target)")
        }

        element.tap()
        return successJSON(["tapped": target])
    }

    func handleDoubleTap(params: [String: Any]) -> String {
        guard let target = params["target"] as? String else {
            return errorJSON("missing 'target' param")
        }
        guard let element = findElement(target: target, params: params), element.exists else {
            return errorJSON("element not found: \(target)")
        }
        element.doubleTap()
        return successJSON(["doubleTapped": target])
    }

    func handleLongPress(params: [String: Any]) -> String {
        guard let target = params["target"] as? String else {
            return errorJSON("missing 'target' param")
        }
        let duration = params["duration"] as? Double ?? 1.0
        guard let element = findElement(target: target, params: params), element.exists else {
            return errorJSON("element not found: \(target)")
        }
        element.press(forDuration: duration)
        return successJSON(["longPressed": target, "duration": duration])
    }

    // MARK: - Type / Clear

    func handleTypeText(params: [String: Any]) -> String {
        guard let text = params["text"] as? String else {
            return errorJSON("missing 'text' param")
        }

        // If a target is specified, tap it first to focus
        if let target = params["target"] as? String {
            guard let element = findElement(target: target, params: params), element.exists else {
                return errorJSON("element not found: \(target)")
            }
            element.tap()
            usleep(200_000) // Wait for keyboard
        }

        currentApp.typeText(text)
        return successJSON(["typed": text.count])
    }

    func handleClear(params: [String: Any]) -> String {
        guard let target = params["target"] as? String else {
            return errorJSON("missing 'target' param")
        }
        guard let element = findElement(target: target, params: params), element.exists else {
            return errorJSON("element not found: \(target)")
        }

        // Triple-tap to select all, then delete
        element.tap()
        element.press(forDuration: 1.2)

        let selectAll = currentApp.menuItems["Select All"]
        if selectAll.waitForExistence(timeout: 2) {
            selectAll.tap()
            currentApp.typeText(XCUIKeyboardKey.delete.rawValue)
        } else {
            // Fallback: use keyboard shortcut
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue,
                                   count: (element.value as? String)?.count ?? 50))
        }

        return successJSON(["cleared": target])
    }

    // MARK: - Wait

    func handleWaitFor(params: [String: Any]) -> String {
        guard let target = params["target"] as? String else {
            return errorJSON("missing 'target' param")
        }
        let timeout = params["timeout"] as? Double ?? 10.0
        let app = resolveApp(params: params)

        let predicate = NSPredicate(format:
            "label CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@ OR value CONTAINS[cd] %@",
            target, target, target)
        let element = app.descendants(matching: .any).matching(predicate).firstMatch

        let found = element.waitForExistence(timeout: timeout)
        if found {
            return successJSON(["found": true, "target": target])
        } else {
            return errorJSON("timeout waiting for: \(target)")
        }
    }

    // MARK: - Screenshot

    func handleScreenshot(params: [String: Any]) -> String {
        let screenshot = currentApp.screenshot()
        let pngData = screenshot.pngRepresentation

        if let path = params["path"] as? String {
            let url = URL(fileURLWithPath: path)
            do {
                try pngData.write(to: url)
                return successJSON(["saved": path, "size": pngData.count])
            } catch {
                return errorJSON("failed to write screenshot: \(error.localizedDescription)")
            }
        } else {
            // Return base64 encoded if no path
            let base64 = pngData.base64EncodedString()
            return successJSON(["base64": base64, "size": pngData.count])
        }
    }

    // MARK: - App lifecycle

    func handleLaunch(params: [String: Any]) -> String {
        let bundleId = params["bundleId"] as? String

        if let bundleId = bundleId {
            let targetApp = XCUIApplication(bundleIdentifier: bundleId)
            if let envVars = params["envVars"] as? [String: String] {
                targetApp.launchEnvironment = envVars
            }
            // If the app is already running, activate it (brings to fg without
            // kill-and-restart). Otherwise full launch.
            if targetApp.state == .runningForeground {
                targetApp.activate()
            } else {
                targetApp.launch()
            }

            activeApp = targetApp
            activeBundleId = bundleId
            return successJSON(["launched": bundleId])
        } else {
            app.launch()
            activeApp = app
            return successJSON(["launched": "default"])
        }
    }

    func handleTerminate(params: [String: Any]) -> String {
        let bundleId = params["bundleId"] as? String

        if let bundleId = bundleId {
            let targetApp = XCUIApplication(bundleIdentifier: bundleId)
            targetApp.terminate()
            return successJSON(["terminated": bundleId])
        } else {
            currentApp.terminate()
            return successJSON(["terminated": "default"])
        }
    }

    // MARK: - Scroll / Swipe

    func handleScroll(params: [String: Any]) -> String {
        guard let direction = params["direction"] as? String else {
            return errorJSON("missing 'direction' param")
        }

        let target = params["target"] as? String
        let element: XCUIElement
        if let target = target, let found = findElement(target: target, params: params), found.exists {
            element = found
        } else {
            element = app
        }

        switch direction.lowercased() {
        case "up":    element.swipeUp()
        case "down":  element.swipeDown()
        case "left":  element.swipeLeft()
        case "right": element.swipeRight()
        default:
            return errorJSON("invalid direction: \(direction)")
        }

        return successJSON(["scrolled": direction])
    }

    func handleSwipe(params: [String: Any]) -> String {
        guard let direction = params["direction"] as? String else {
            return errorJSON("missing 'direction' param")
        }

        switch direction.lowercased() {
        case "up":    currentApp.swipeUp()
        case "down":  currentApp.swipeDown()
        case "left":  currentApp.swipeLeft()
        case "right": currentApp.swipeRight()
        default:
            return errorJSON("invalid direction: \(direction)")
        }

        return successJSON(["swiped": direction])
    }

    // MARK: - Viewport

    /// Returns the app's frame as viewport bounds.
    /// Used by the host (XCUIBridge) to validate element visibility before
    /// considering scrollTo "found".
    func handleViewport(params: [String: Any]) -> String {
        let app = resolveApp(params: params)
        let frame = app.frame
        return successJSON(["viewport": [
            "x": Int(frame.origin.x),
            "y": Int(frame.origin.y),
            "width": Int(frame.size.width),
            "height": Int(frame.size.height)
        ]])
    }

    // MARK: - Keyboard

    func handleHideKeyboard() -> String {
        // Tap on a non-interactive area to dismiss keyboard
        let coord = currentApp.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.1))
        coord.tap()
        return successJSON(["keyboard": "dismissed"])
    }

    // MARK: - Element resolution

    /// Find element by label, identifier, or value. Supports [N] index suffix.
    private func findElement(target: String, params: [String: Any]) -> XCUIElement? {
        var query = target
        var index: Int?

        // Parse [N] index suffix: "Login[2]" → target="Login", index=2
        if let bracketStart = target.lastIndex(of: "["),
           let bracketEnd = target.lastIndex(of: "]"),
           bracketStart < bracketEnd {
            let idxStr = String(target[target.index(after: bracketStart)..<bracketEnd])
            if let n = Int(idxStr) {
                index = n
                query = String(target[target.startIndex..<bracketStart])
            }
        }

        // Role filter from params
        let role = params["role"] as? String

        // Always resolve the current app fresh to pick up external launch/terminate
        let app = resolveApp(params: params)

        // ──────────────────────────────────────────────────────────────
        // FAST PATH — typed query by role + direct subscript.
        // XCTest is MUCH faster when you query a specific type than
        // when you use `descendants(matching: .any)`. For common roles
        // we skip the full tree scan entirely.
        //
        // `app.buttons[label]` returns an XCUIElement without fetching
        // the snapshot until the first access — orders of magnitude
        // faster than NSPredicate-based filtering.
        // ──────────────────────────────────────────────────────────────
        if role == nil, index == nil, params["within"] == nil {
            // Try typed queries for the most common element types.
            // These are O(1) lookups that don't scan the whole tree.
            let typedCandidates: [XCUIElementQuery] = [
                app.buttons,
                app.staticTexts,
                app.textFields,
                app.secureTextFields,
                app.searchFields,
                app.switches,
                app.cells,
                app.links
            ]
            for q in typedCandidates {
                let byLabel = q[query]
                if byLabel.exists { return byLabel }
            }
        }

        // Within scope
        let scope: XCUIElement
        if let within = params["within"] as? String {
            let scopePredicate = NSPredicate(format:
                "label CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@", within, within)
            let scopeMatch = app.descendants(matching: .any).matching(scopePredicate).firstMatch
            scope = scopeMatch.exists ? scopeMatch : app
        } else {
            scope = app
        }

        // SLOW PATH — predicate-based fallback for cases where typed query missed.
        let predicate = NSPredicate(format:
            "label ==[cd] %@ OR identifier ==[cd] %@ OR value ==[cd] %@",
            query, query, query)

        let elementType: XCUIElement.ElementType = role.flatMap { mapRole($0) } ?? .any
        let matches = scope.descendants(matching: elementType).matching(predicate)

        if let index = index {
            // 1-based index
            let idx = index - 1
            guard idx >= 0, idx < matches.count else { return nil }
            let el = matches.element(boundBy: idx)
            return el.exists ? el : nil
        }

        let first = matches.firstMatch
        if first.exists { return first }

        // Loose fallback: CONTAINS instead of exact match
        let loosePredicate = NSPredicate(format:
            "label CONTAINS[cd] %@ OR identifier CONTAINS[cd] %@", query, query)
        let looseMatches = scope.descendants(matching: elementType).matching(loosePredicate)
        let looseFirst = looseMatches.firstMatch
        return looseFirst.exists ? looseFirst : nil
    }

    private func mapRole(_ role: String) -> XCUIElement.ElementType? {
        switch role.lowercased() {
        case "button":      return .button
        case "textfield":   return .textField
        case "securetextfield": return .secureTextField
        case "searchfield": return .searchField
        case "textview", "textarea": return .textView
        case "statictext":  return .staticText
        case "image":       return .image
        case "cell":        return .cell
        case "switch", "toggle": return .switch
        case "slider":      return .slider
        case "link":        return .link
        case "navbar", "navigationbar": return .navigationBar
        case "tabbar":      return .tabBar
        case "table":       return .table
        case "scrollview":  return .scrollView
        case "picker":      return .picker
        case "alert":       return .alert
        case "sheet":       return .sheet
        default:            return nil
        }
    }
}
