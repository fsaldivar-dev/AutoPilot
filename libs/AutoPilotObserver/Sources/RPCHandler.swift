import UIKit

final class RPCHandler {

    func handle(_ request: [String: Any]) -> [String: Any] {
        guard let method = request["method"] as? String else {
            return ["error": "missing method"]
        }
        let params = request["params"] as? [String: Any]

        switch method {
        case "ping":
            // #154: handshake — además del pong, reportar el bundleId REAL del
            // proceso. El puerto 7002 es fijo: si otra app lo retiene, el CLI
            // compara este valor con el bundle lanzado y avisa en vez de
            // reportar "with observer" engañosamente. Mismo patrón que el
            // agente Android (ping devuelve "api" como sibling key).
            return ["result": "pong",
                    "bundleId": Bundle.main.bundleIdentifier ?? ""]

        case "tree":
            // Warm AX (framework load is one-time; the screenChanged post is
            // cheap) in its own main-thread hop, then serialize in a second hop
            // so the main runloop can process the AX notification in between.
            // The old fixed usleep(100ms) was removed: if the UI is mid-
            // transition, waiting is the CLIENT's responsibility (waitFor),
            // not a per-read tax.
            DispatchQueue.main.sync { warmupAccessibility() }
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
            // No fixed sleep (see "tree") — exists is the primitive that the
            // client polls (waitFor / waitUntilGone), so it must return fast;
            // retrying is the client's job.
            let target = params?["target"] as? String ?? ""
            DispatchQueue.main.sync { warmupAccessibility() }
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
            // performSwipe no lanza — sin do/catch (el catch era inalcanzable).
            let direction = params?["direction"] as? String ?? "up"
            performSwipe(direction: direction)
            return ["result": true]

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
                _ = UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                                    to: nil, from: nil, for: nil)
            }
            return ["result": true]

        default:
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - Actions

    private func performTap(target: String) throws {
        let resolved = try resolveTarget(target)
        DispatchQueue.main.sync {
            switch resolved {
            case .view(let v):
                if let ctrl = v as? UIControl {
                    ctrl.sendActions(for: .touchUpInside)
                } else {
                    _ = v.accessibilityActivate()
                }
            case .axNode(let node):
                _ = node.accessibilityActivate?()
            case .barButton(let item):
                // UIBarButtonItem invokes its action by sending the selector to the target.
                if let action = item.action, let t = item.target {
                    _ = t.perform(action, with: item)
                }
            }
        }
    }

    // MARK: - Target resolution

    private enum ResolvedTarget {
        case view(UIView)
        case axNode(AnyObject)
        case barButton(UIBarButtonItem)
    }

    /// Resolves a tap target with the same priority as before (UIView →
    /// SwiftUI/UIAccessibilityElement AX node → UIBarButtonItem).
    ///
    /// Matching, in order (parity with the classic TargetResolver path):
    ///   1. exact (label / identifier / text / title)
    ///   2. case-insensitive prefix
    ///   3. case-insensitive contains
    /// A unique fuzzy candidate is tapped; multiple candidates throw an
    /// ambiguity error listing the matches so the caller can disambiguate.
    ///
    /// Latency: the old code always slept 100 ms before searching. Now the
    /// happy path (element already published) costs ~0 ms; only when nothing
    /// matches do we yield the main runloop in 5 ms steps for up to ~100 ms —
    /// SwiftUI publishes accessibilityElements one runloop turn after the
    /// screenChanged warmup post, so mid-transition taps still land. Longer
    /// settles remain the CLIENT's responsibility (waitFor).
    private func resolveTarget(_ target: String) throws -> ResolvedTarget {
        let deadline = Date().addingTimeInterval(0.1)
        while true {
            DispatchQueue.main.sync { warmupAccessibility() }

            var exact: ResolvedTarget?
            DispatchQueue.main.sync {
                if let v = ViewSerializer.findView(matching: target) {
                    exact = .view(v)
                } else if let n = ViewSerializer.findAXElement(matching: target) {
                    exact = .axNode(n)
                } else if let b = ViewSerializer.findBarButtonItem(matching: target) {
                    exact = .barButton(b)
                }
            }
            if let match = exact { return match }

            // Fuzzy fallback: prefix first, then contains (case-insensitive).
            var fuzzy: [(object: ViewSerializer.Candidate, label: String)] = []
            DispatchQueue.main.sync {
                let query = target.lowercased()
                fuzzy = ViewSerializer.collectCandidates { $0.lowercased().hasPrefix(query) }
                if fuzzy.isEmpty {
                    fuzzy = ViewSerializer.collectCandidates { $0.lowercased().contains(query) }
                }
            }
            // Collapse candidates that matched with the SAME text (a UIButton
            // and its internal titleLabel, a row container and its text node):
            // first wins, same semantics as the exact path. Ambiguity is only
            // reported when DIFFERENT labels match.
            var seenLabels = Set<String>()
            fuzzy = fuzzy.filter { seenLabels.insert($0.label).inserted }
            if fuzzy.count == 1 {
                switch fuzzy[0].object {
                case .view(let v):      return .view(v)
                case .axElement(let n): return .axNode(n)
                case .barButton(let b): return .barButton(b)
                }
            }
            if fuzzy.count > 1 {
                // Ambiguity is a stable state — fail fast, listing matches.
                throw ObserverError.ambiguousTarget(target, fuzzy.map { $0.label })
            }

            guard Date() < deadline else { throw ObserverError.elementNotFound(target) }
            usleep(5_000) // let the main runloop publish the AX tree, retry
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
            // Paging directo sobre UIScrollView (#153): `accessibilityScroll`
            // es un no-op en UIScrollView plano (UIKit no lo implementa; el
            // scroll AX real lo hace VoiceOver via setContentOffset). Ese
            // no-op silencioso era el "scrollTo sin scrollear" del QA.
            // setContentOffset con clamp es determinista y reporta si de
            // verdad hubo a dónde moverse.
            if let sv = findScrollView(forGesture: direction), pageScroll(sv, gesture: direction) {
                return
            }
            if let sv = findAnyScrollView() {
                _ = sv.accessibilityScroll(dir)
            } else if let window = firstWindow() {
                _ = window.accessibilityScroll(dir)
            }
        }
    }

    /// Swipe con semántica de GESTO: "up" = dedo hacia arriba = el contenido
    /// de abajo entra en pantalla (offset.y crece). Pagina el 80% del alto
    /// visible, clampeado al contentSize. Devuelve false si no había a dónde
    /// scrollear en esa dirección (fin del contenido).
    private func pageScroll(_ sv: UIScrollView, gesture: String) -> Bool {
        var offset = sv.contentOffset
        let pageY = sv.bounds.height * 0.8
        let pageX = sv.bounds.width * 0.8
        let minY = -sv.adjustedContentInset.top
        let maxY = max(minY, sv.contentSize.height + sv.adjustedContentInset.bottom - sv.bounds.height)
        let minX = -sv.adjustedContentInset.left
        let maxX = max(minX, sv.contentSize.width + sv.adjustedContentInset.right - sv.bounds.width)
        switch gesture.lowercased() {
        case "up":    offset.y = min(offset.y + pageY, maxY)
        case "down":  offset.y = max(offset.y - pageY, minY)
        case "left":  offset.x = min(offset.x + pageX, maxX)
        case "right": offset.x = max(offset.x - pageX, minX)
        default:      return false
        }
        guard offset != sv.contentOffset else { return false }
        sv.setContentOffset(offset, animated: true)
        return true
    }

    /// Primer UIScrollView que PUEDE scrollear en el eje del gesto. El
    /// `findAnyScrollView` genérico puede devolver un carrusel horizontal
    /// (chips, fotos) cuando el gesto es vertical — y el swipe se perdería.
    private func findScrollView(forGesture gesture: String) -> UIScrollView? {
        let vertical = gesture.lowercased() == "up" || gesture.lowercased() == "down"
        for window in allWindows() {
            let found = firstDescendant(window, matching: {
                guard let s = $0 as? UIScrollView else { return false }
                return vertical
                    ? s.contentSize.height > s.bounds.height + 1
                    : s.contentSize.width > s.bounds.width + 1
            })
            if let sv = found as? UIScrollView { return sv }
        }
        return nil
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

    /// PRECONDICIÓN: debe llamarse YA en la main queue. Sus callers (typeText,
    /// performPressKey) se ejecutan dentro de `DispatchQueue.main.sync` desde
    /// `handle()`; abrir aquí OTRO `main.sync` producía un deadlock del hilo
    /// consigo mismo → EXC_BREAKPOINT que mataba la app en cada `type` (#165).
    private func findFirstResponder() -> UIResponder? {
        dispatchPrecondition(condition: .onQueue(.main))
        let windows: [UIWindow]
        if #available(iOS 13, *) {
            windows = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
        } else {
            windows = UIApplication.shared.windows
        }
        for window in windows {
            if let r = window.firstResponder { return r }
        }
        return nil
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

/// Private AX frameworks whose +load / init hooks wake the SwiftUI hosting
/// view's accessibilityElements. Empirical finding from the ARD-002 device
/// spike. Paths are hardcoded — see `axFrameworksLoaded` for the explicit
/// degradation when an OS version moves/renames them.
private let axFrameworkPaths = [
    "/System/Library/AccessibilityBundles/UIKit.axbundle",
    "/System/Library/PrivateFrameworks/AccessibilityUtilities.framework",
    "/System/Library/PrivateFrameworks/AXRuntime.framework"
]

/// One-time AX framework load (lazy globals use swift_once — thread-safe,
/// executed exactly once). Bundle.load() was always idempotent, but calling it
/// per-RPC still paid Bundle(path:) + load() checks on the hot path; now taps
/// pay only the screenChanged post.
///
/// Degradation is explicit, not silent: if a path doesn't exist on this OS
/// (private frameworks move between iOS versions) or fails to load, we log it
/// via NSLog so `simctl spawn log` shows why the SwiftUI AX tree stays dormant.
private let axFrameworksLoaded: Bool = {
    var allLoaded = true
    for path in axFrameworkPaths {
        guard FileManager.default.fileExists(atPath: path) else {
            NSLog("[AutoPilotObserver] AX framework NOT FOUND at %@ — SwiftUI accessibility tree may stay dormant on this OS version", path)
            allLoaded = false
            continue
        }
        guard let bundle = Bundle(path: path), bundle.load() else {
            NSLog("[AutoPilotObserver] failed to load AX framework at %@", path)
            allLoaded = false
            continue
        }
    }
    return allLoaded
}()

/// Must be called on the main thread. The framework load happens once (see
/// `axFrameworksLoaded`); the screenChanged post stays per-call because
/// SwiftUI rebuilds its AX tree on each screen transition and keeps it
/// dormant until an AX client nudges it.
func warmupAccessibility() {
    _ = axFrameworksLoaded
    UIAccessibility.post(notification: .screenChanged, argument: nil)
}

// MARK: - Errors

enum ObserverError: Error, LocalizedError {
    case elementNotFound(String)
    case ambiguousTarget(String, [String])

    var errorDescription: String? {
        switch self {
        case .elementNotFound(let t):
            return "element not found: \(t)"
        case .ambiguousTarget(let t, let matches):
            return "ambiguous target '\(t)' matches \(matches.count) elements: \(matches.joined(separator: " | "))"
        }
    }
}
