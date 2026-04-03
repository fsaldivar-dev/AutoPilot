import Foundation

/// Platform-agnostic element indexer that works with JSON tree data
/// (the format returned by DeviceBridge.tree()).
/// Assigns sequential $N indices to interactive/labeled elements,
/// filtering out generic containers without useful info.
public final class ElementIndexShared {

    public struct Entry {
        public let index: Int
        public let role: String
        public let label: String
        public let id: String
        public let frame: String
    }

    private var entries: [Entry] = []

    public init() {}

    /// Generic container roles that get filtered when they have no label.
    private static let containerRoles: Set<String> = [
        "FrameLayout", "LinearLayout", "ViewGroup", "RelativeLayout",
        "ConstraintLayout", "CoordinatorLayout", "ScrollView",
        "HorizontalScrollView", "RecyclerView", "ListView",
        "android.view.View", "View"
    ]

    /// Interactive roles that are always indexed (even without label, if they have *some* identifier).
    private static let interactiveRoles: Set<String> = [
        "Button", "EditText", "CheckBox", "Switch", "SeekBar",
        "ImageButton", "ToggleButton", "RadioButton", "Spinner",
        "android.widget.Button", "android.widget.EditText",
        "android.widget.CheckBox", "android.widget.Switch",
        "android.widget.SeekBar", "android.widget.ImageButton",
        "android.widget.ToggleButton", "android.widget.RadioButton",
        "android.widget.Spinner"
    ]

    /// Labeled static roles that get indexed when they have a label.
    private static let labeledStaticRoles: Set<String> = [
        "TextView", "ImageView", "android.widget.TextView",
        "android.widget.ImageView"
    ]

    /// Build the index from a tree returned by DeviceBridge.tree().
    public func build(from tree: [[String: Any]]) {
        entries = []
        for element in tree {
            indexElement(element, depth: 0)
        }
    }

    private func indexElement(_ element: [String: Any], depth: Int) {
        guard depth < 30 else { return }

        let role = element["role"] as? String ?? ""
        let title = element["title"] as? String ?? ""
        let label = element["label"] as? String ?? ""
        let identifier = element["identifier"] as? String ?? ""
        let display = element["display"] as? String ?? ""

        // Determine the effective label (best human-readable text)
        let effectiveLabel: String = {
            if !title.isEmpty { return title }
            if !label.isEmpty { return label }
            if !display.isEmpty && display != role { return display }
            return ""
        }()

        let effectiveId = identifier

        // Determine the short role name (strip package prefix)
        let shortRole: String = {
            if let dot = role.lastIndex(of: ".") {
                return String(role[role.index(after: dot)...])
            }
            return role
        }()

        let isInteractive = Self.interactiveRoles.contains(role) || Self.interactiveRoles.contains(shortRole)
        let isLabeledStatic = Self.labeledStaticRoles.contains(role) || Self.labeledStaticRoles.contains(shortRole)
        let isContainer = Self.containerRoles.contains(role) || Self.containerRoles.contains(shortRole)
        let hasLabel = !effectiveLabel.isEmpty || !effectiveId.isEmpty

        // Index logic:
        // - Interactive elements: always index if they have any identifier
        // - Labeled static elements: index if they have a label
        // - Containers without labels: skip
        let shouldIndex: Bool
        if isInteractive && hasLabel {
            shouldIndex = true
        } else if isLabeledStatic && hasLabel {
            shouldIndex = true
        } else if !isContainer && hasLabel {
            // Unknown role but has a label — index it
            shouldIndex = true
        } else {
            shouldIndex = false
        }

        if shouldIndex {
            // Build frame string
            var frameStr = ""
            if let frame = element["frame"] as? [String: Any] {
                let x = frame["x"] ?? 0
                let y = frame["y"] ?? 0
                let w = frame["width"] ?? 0
                let h = frame["height"] ?? 0
                frameStr = "[\(x),\(y) \(w)x\(h)]"
            } else if let frame = element["frame"] as? String, !frame.isEmpty {
                frameStr = frame
            }

            entries.append(Entry(
                index: entries.count,
                role: shortRole,
                label: effectiveLabel,
                id: effectiveId,
                frame: frameStr
            ))
        }

        // Recurse into children
        if let children = element["children"] as? [[String: Any]] {
            for child in children {
                indexElement(child, depth: depth + 1)
            }
        }
    }

    /// Get element by index.
    public func get(_ index: Int) -> Entry? {
        guard index >= 0 && index < entries.count else { return nil }
        return entries[index]
    }

    /// All entries.
    public var all: [Entry] { entries }

    /// Count of indexed elements.
    public var count: Int { entries.count }

    /// Find entries matching a label/id (case-insensitive substring).
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
            let role = entry.role.padding(toLength: 14, withPad: " ", startingAt: 0)
            let label = entry.label.isEmpty ? entry.id : entry.label
            let display = label.isEmpty ? "(no label)" : "\"\(label)\""
            print("\(idx) \(role) \(display.padding(toLength: 30, withPad: " ", startingAt: 0)) \(entry.frame)")
        }
        print("\n\(entries.count) element(s) indexed")
    }
}
