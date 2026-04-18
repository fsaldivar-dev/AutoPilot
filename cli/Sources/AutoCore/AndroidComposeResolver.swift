import Foundation

/// En Compose los click handlers viven en `Button`, no en `TextView`. Cuando un
/// match cae sobre un TextView hay que subir al Button contenedor más pequeño.
/// Esto resuelve el issue #59 (Android Compose buttons sin contentDescription).
public enum AndroidComposeResolver {

    public static func findClickableFrame(for element: [String: Any], in tree: [[String: Any]]) -> [String: Any]? {
        guard let frame = element["frame"] as? [String: Any],
              let ex = frame["x"] as? Int, let ey = frame["y"] as? Int else { return nil }
        return findButtonContaining(x: ex, y: ey, in: tree)
    }

    public static func findButtonContaining(x: Int, y: Int, in elements: [[String: Any]]) -> [String: Any]? {
        var bestFrame: [String: Any]?
        var bestArea = Int.max
        findSmallest(x: x, y: y, in: elements, bestFrame: &bestFrame, bestArea: &bestArea)
        return bestFrame
    }

    private static func findSmallest(x: Int, y: Int, in elements: [[String: Any]], bestFrame: inout [String: Any]?, bestArea: inout Int) {
        for element in elements {
            let role = (element["role"] as? String) ?? ""
            let clickable = (element["clickable"] as? Bool) ?? false

            if (role == "Button" || clickable),
               let frame = element["frame"] as? [String: Any],
               let fx = frame["x"] as? Int, let fy = frame["y"] as? Int,
               let fw = frame["width"] as? Int, let fh = frame["height"] as? Int {
                let area = fw * fh
                if x >= fx && x <= fx + fw && y >= fy && y <= fy + fh && area < bestArea {
                    bestArea = area
                    bestFrame = frame
                }
            }
            if let children = element["children"] as? [[String: Any]] {
                findSmallest(x: x, y: y, in: children, bestFrame: &bestFrame, bestArea: &bestArea)
            }
        }
    }
}
