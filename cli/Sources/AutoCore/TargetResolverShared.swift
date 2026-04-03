import Foundation

/// Platform-agnostic target resolver for Label[N] and $N syntax.
/// Pure string parsing — no AX or platform dependencies.
public struct TargetResolverShared {

    /// Parse a target string into label and optional occurrence index.
    /// "Camera[2]" → ("Camera", 2)
    /// "Camera"    → ("Camera", nil)
    /// "$5"        → ("$5", nil) — caller handles $N separately
    public static func parse(_ target: String) -> (label: String, index: Int?) {
        // Check for [N] suffix
        if let bracket = target.lastIndex(of: "["),
           let end = target.lastIndex(of: "]"),
           bracket < end {
            let label = String(target[target.startIndex..<bracket])
            let numStr = String(target[target.index(after: bracket)..<end])
            if let n = Int(numStr) {
                return (label, n)
            }
        }
        return (target, nil)
    }

    /// Check if a target is a $N index reference.
    /// Returns the index number if it is, nil otherwise.
    public static func parseIndex(_ target: String) -> Int? {
        guard target.hasPrefix("$"),
              let n = Int(target.dropFirst()) else { return nil }
        return n
    }

    /// Search a tree (from DeviceBridge.tree()) for all elements matching a label.
    /// Returns matches with their 1-based occurrence number.
    public static func findAll(in tree: [[String: Any]], matching label: String) -> [(element: [String: Any], occurrence: Int)] {
        var results: [(element: [String: Any], occurrence: Int)] = []
        var count = 0
        let query = label.lowercased()
        findRecursive(elements: tree, query: query, results: &results, count: &count)
        return results
    }

    private static func findRecursive(elements: [[String: Any]], query: String, results: inout [(element: [String: Any], occurrence: Int)], count: inout Int) {
        for element in elements {
            let title = (element["title"] as? String ?? "").lowercased()
            let label = (element["label"] as? String ?? "").lowercased()
            let identifier = (element["identifier"] as? String ?? "").lowercased()
            let display = (element["display"] as? String ?? "").lowercased()

            let matches = title.contains(query) ||
                         label.contains(query) ||
                         identifier.contains(query) ||
                         display.contains(query) ||
                         title == query ||
                         label == query

            if matches {
                count += 1
                results.append((element: element, occurrence: count))
            }

            if let children = element["children"] as? [[String: Any]] {
                findRecursive(elements: children, query: query, results: &results, count: &count)
            }
        }
    }
}
