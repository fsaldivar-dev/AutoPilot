import Foundation
import CoreGraphics

// MARK: - RecorderScrollHelper
//
// Shared logic for auto-injecting `scrollUntilVisible` lines into recorded
// scripts when the tapped element exists in the tree but is outside the
// viewport. iOS and Android recorders use the same rule; they just source
// the tree differently (Android uses a cached tree because uiautomator dump
// is 1-2s; iOS fetches fresh because AX is ~300ms).

public enum RecorderScrollHelper {

    /// If `selector` resolves to an element whose frame is offscreen, returns
    /// the `scrollUntilVisible "..."` line to emit. Returns nil if the element
    /// is visible (or can't be located/located without a frame).
    public static func scrollLine(forSelector selector: String,
                                  in tree: [[String: Any]],
                                  viewport: CGRect) -> String? {
        guard let match = ViewportUtil.findFirst(in: tree, matching: selector),
              let frame = ViewportUtil.rect(from: match["frame"] as? [String: Any]) else {
            return nil
        }
        let vp = ViewportUtil.resolveViewport(for: match, in: tree, screenBounds: viewport)
        if ViewportUtil.isVisible(frame: frame, inViewport: vp) {
            return nil
        }
        // Escape double-quotes so the emitted line round-trips through
        // ScriptParser.tokenize() correctly.
        let escaped = selector.replacingOccurrences(of: "\"", with: "\\\"")
        return "scrollUntilVisible \"\(escaped)\""
    }
}
