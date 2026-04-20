import UIKit

final class RPCHandler {

    func handle(_ request: [String: Any]) -> [String: Any] {
        guard let method = request["method"] as? String else {
            return ["error": "missing method"]
        }
        let params = request["params"] as? [String: Any]

        switch method {
        case "ping":
            return ["result": "pong"]

        case "tree":
            // Step 1: warm AX subsystem on main thread
            DispatchQueue.main.sync { warmupAccessibility() }
            // Step 2: yield to main thread so SwiftUI can process the AX
            // notification and build _UIHostingView.accessibilityElements
            usleep(100_000)
            // Step 3: serialize the tree
            var tree: [[String: Any]] = []
            DispatchQueue.main.sync { tree = ViewSerializer.serialize() }
            return ["result": tree]

        case "tap":
            let target = params?["target"] as? String ?? ""
            do {
                try performTap(target: target)
                return ["result": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "doubleTap":
            let target = params?["target"] as? String ?? ""
            do {
                try performTap(target: target)
                try performTap(target: target)
                return ["result": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "exists":
            let target = params?["target"] as? String ?? ""
            DispatchQueue.main.sync { warmupAccessibility() }
            usleep(100_000)
            var found = false
            DispatchQueue.main.sync {
                found = ViewSerializer.findView(matching: target) != nil
                    || ViewSerializer.findAXElement(matching: target) != nil
            }
            return ["result": found]

        case "type":
            let text = params?["text"] as? String ?? ""
            DispatchQueue.main.sync { typeText(text) }
            return ["result": true]

        case "clear":
            let target = params?["target"] as? String ?? ""
            do {
                try clearField(target: target)
                return ["result": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "viewport":
            var rect: CGRect = .zero
            DispatchQueue.main.sync {
                if #available(iOS 13, *) {
                    rect = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .first?.screen.bounds ?? .zero
                } else {
                    rect = UIScreen.main.bounds
                }
            }
            return ["result": ["x": rect.origin.x, "y": rect.origin.y,
                               "w": rect.size.width, "h": rect.size.height] as [String: Any]]

        case "longPress":
            // Best-effort: AX protocol has no first-class long-press verb.
            // For interactive elements, accessibilityActivate triggers the
            // primary action; for SwiftUI `.contextMenu` attached views there's
            // typically a separate AccessibilityCustomAction — not reachable
            // without synth touches. Fall back to a regular activate.
            let target = params?["target"] as? String ?? ""
            do {
                try performTap(target: target)
                return ["result": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "scroll":
            let target = params?["target"] as? String ?? ""
            let direction = params?["direction"] as? String ?? "down"
            do {
                try performScroll(target: target, direction: direction)
                return ["result": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "swipe":
            let direction = params?["direction"] as? String ?? "up"
            do {
                try performSwipe(direction: direction)
                return ["result": true]
            } catch {
                return ["error": error.localizedDescription]
            }

        case "tapAt":
            let x = (params?["x"] as? Double) ?? (params?["x"] as? Int).map(Double.init) ?? 0
            let y = (params?["y"] as? Double) ?? (params?["y"] as? Int).map(Double.init) ?? 0
            DispatchQueue.main.sync { performTapAt(x: x, y: y) }
            return ["result": true]

        case "pressKey":
            let key = params?["key"] as? String ?? ""
            DispatchQueue.main.sync { performPressKey(key: key) }
            return ["result": true]

        case "hideKeyboard":
            DispatchQueue.main.sync {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                 to: nil, from: nil, for: nil)
            }
            return ["result": true]

        default:
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - Actions

    private func performTap(target: String) throws {
        // Step 1: warm AX subsystem
        DispatchQueue.main.sync { warmupAccessibility() }
        // Step 2: yield so SwiftUI builds its AX tree
        usleep(100_000)

        // Try UIView first (UIKit apps)
        var view: UIView?
        DispatchQueue.main.sync { view = ViewSerializer.findView(matching: target) }
        if let v = view {
            DispatchQueue.main.sync {
                if let ctrl = v as? UIControl {
                    ctrl.sendActions(for: .touchUpInside)
                } else {
                    _ = v.accessibilityActivate()
                }
            }
            return
        }

        // Try any AX node (SwiftUI AccessibilityNode, UIAccessibilityElement).
        // SwiftUI elements are on _UIHostingView.accessibilityElements.
        var axNode: AnyObject?
        DispatchQueue.main.sync { axNode = ViewSerializer.findAXElement(matching: target) }
        if let node = axNode {
            DispatchQueue.main.sync {
                _ = node.accessibilityActivate?()
            }
            return
        }

        // Try UIBarButtonItem (UINavigationBar / UIToolbar items are NOT UIViews).
        var bbi: UIBarButtonItem?
        DispatchQueue.main.sync { bbi = ViewSerializer.findBarButtonItem(matching: target) }
        guard let item = bbi else { throw ObserverError.elementNotFound(target) }
        DispatchQueue.main.sync {
            // UIBarButtonItem invokes its action by sending the selector to the target.
            if let action = item.action, let t = item.target {
                _ = t.perform(action, with: item)
            }
        }
    }

    private func typeText(_ text: String) {
        guard let responder = findFirstResponder() else { return }
        if let textField = responder as? UITextField {
            textField.insertText(text)
        } else if let textView = responder as? UITextView {
            textView.insertText(text)
        }
    }

    private func clearField(target: String) throws {
        var view: UIView?
        DispatchQueue.main.sync { view = ViewSerializer.findView(matching: target) }
        guard let v = view else { throw ObserverError.elementNotFound(target) }

        DispatchQueue.main.sync {
            if let textField = v as? UITextField {
                textField.text = ""
                textField.sendActions(for: .editingChanged)
            } else if let textView = v as? UITextView {
                textView.text = ""
            }
        }
    }

    private func performScroll(target: String, direction: String) throws {
        let dir = axScrollDirection(direction)
        var view: UIView?
        DispatchQueue.main.sync { view = ViewSerializer.findView(matching: target) }

        // If we can't find the named view, try scrolling any UIScrollView in
        // the hierarchy — better than nothing for generic scroll prompts.
        let scrollView: UIView
        if let v = view {
            scrollView = enclosingScrollView(v) ?? v
        } else if let sv = findAnyScrollView() {
            scrollView = sv
        } else {
            throw ObserverError.elementNotFound(target)
        }
        DispatchQueue.main.sync { _ = scrollView.accessibilityScroll(dir) }
    }

    private func performSwipe(direction: String) {
        let dir = axScrollDirection(direction)
        DispatchQueue.main.sync {
            if let sv = findAnyScrollView() {
                _ = sv.accessibilityScroll(dir)
            } else if let window = firstWindow() {
                _ = window.accessibilityScroll(dir)
            }
        }
    }

    private func performTapAt(x: Double, y: Double) {
        guard let window = firstWindow() else { return }
        let point = CGPoint(x: x, y: y)
        if let hit = window.hitTest(point, with: nil) {
            if let ctrl = hit as? UIControl {
                ctrl.sendActions(for: .touchUpInside)
            } else {
                _ = hit.accessibilityActivate()
            }
        }
    }

    private func performPressKey(key: String) {
        guard let responder = findFirstResponder() else { return }
        let input: String
        switch key.lowercased() {
        case "enter", "return":     input = "\n"
        case "tab":                 input = "\t"
        case "space":               input = " "
        case "backspace", "delete":
            if let textField = responder as? UITextField { textField.deleteBackward() }
            else if let textView = responder as? UITextView { textView.deleteBackward() }
            return
        default:                    input = key
        }
        if let textField = responder as? UITextField { textField.insertText(input) }
        else if let textView = responder as? UITextView { textView.insertText(input) }
    }

    private func axScrollDirection(_ s: String) -> UIAccessibilityScrollDirection {
        switch s.lowercased() {
        case "up":    return .up
        case "down":  return .down
        case "left":  return .left
        case "right": return .right
        case "next":  return .next
        case "previous", "prev": return .previous
        default:      return .down
        }
    }

    private func enclosingScrollView(_ view: UIView) -> UIView? {
        var current: UIView? = view
        while let v = current {
            if v is UIScrollView { return v }
            current = v.superview
        }
        return nil
    }

    private func findAnyScrollView() -> UIView? {
        for window in allWindows() {
            if let sv = firstDescendant(window, matching: { $0 is UIScrollView }) { return sv }
        }
        return nil
    }

    private func firstDescendant(_ view: UIView, matching predicate: (UIView) -> Bool) -> UIView? {
        if predicate(view) { return view }
        for sub in view.subviews {
            if let found = firstDescendant(sub, matching: predicate) { return found }
        }
        return nil
    }

    private func firstWindow() -> UIWindow? {
        return allWindows().first
    }

    private func allWindows() -> [UIWindow] {
        if #available(iOS 13, *) {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
        }
        return UIApplication.shared.windows
    }

    private func findFirstResponder() -> UIResponder? {
        var responder: UIResponder?
        DispatchQueue.main.sync {
            let windows: [UIWindow]
            if #available(iOS 13, *) {
                windows = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
            } else {
                windows = UIApplication.shared.windows
            }
            for window in windows {
                if let r = window.firstResponder { responder = r; break }
            }
        }
        return responder
    }
}

// MARK: - UIView firstResponder helper

private extension UIView {
    var firstResponder: UIResponder? {
        if isFirstResponder { return self }
        for subview in subviews {
            if let r = subview.firstResponder { return r }
        }
        return nil
    }
}

// MARK: - AX warmup

/// Re-load the private AX frameworks before every tree/tap. SwiftUI rebuilds its
/// AX tree on each screen transition and keeps it dormant until an AX client
/// triggers it. Bundle.load() is idempotent (does nothing if already loaded)
/// but its side-effect — the framework's +load and init hooks — wakes the
/// SwiftUI hosting view's accessibilityElements. Empirical finding from the
/// ARD-002 device spike.
private let axFrameworkPaths = [
    "/System/Library/AccessibilityBundles/UIKit.axbundle",
    "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework",
    "/System/Library/PrivateFrameworks/AXRuntime.framework"
]

/// Must be called on the main thread. Caller is responsible for yielding the
/// main thread after (e.g. `usleep` from a background queue) so SwiftUI can
/// process the screen-changed notification and populate its AX tree.
func warmupAccessibility() {
    for path in axFrameworkPaths {
        if let bundle = Bundle(path: path) { _ = bundle.load() }
    }
    UIAccessibility.post(notification: .screenChanged, argument: nil)
}

// MARK: - Errors

enum ObserverError: Error, LocalizedError {
    case elementNotFound(String)

    var errorDescription: String? {
        switch self {
        case .elementNotFound(let t): return "element not found: \(t)"
        }
    }
}
