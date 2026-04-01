import Foundation

/// Pretty prints the accessibility tree to stdout.
public enum TreePrinter {

    public static func printAX(_ elements: [[String: Any]], indent: Int = 0) {
        for el in elements {
            let prefix = String(repeating: "  ", count: indent)
            let role = el["role"] as? String ?? "?"
            let title = el["title"] as? String ?? ""
            let label = el["label"] as? String ?? ""
            let identifier = el["identifier"] as? String ?? ""
            let value = el["value"] as? String ?? ""
            let frame = el["frame"] as? [String: Any]

            var line = "\(prefix)\(role)"
            if !title.isEmpty { line += "  \"\(title)\"" }
            if !label.isEmpty && label != title { line += "  label=\"\(label)\"" }
            if !identifier.isEmpty { line += "  id=\(identifier)" }
            if !value.isEmpty && value != title { line += "  value=\"\(value)\"" }
            if let f = frame {
                let x = f["x"] as? Int ?? 0
                let y = f["y"] as? Int ?? 0
                let w = f["width"] as? Int ?? 0
                let h = f["height"] as? Int ?? 0
                line += "  [\(x),\(y) \(w)x\(h)]"
            }

            Swift.print(line)

            if let children = el["children"] as? [[String: Any]] {
                printAX(children, indent: indent + 1)
            }
        }
    }
}
