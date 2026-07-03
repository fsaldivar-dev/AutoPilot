import Foundation

// MARK: - ViewFingerprint
//
// Cheap structural hash of a UI snapshot, used to detect whether a tap
// (or any mutating action) had any effect — without paying for a full
// tree dump. Two fingerprints comparing equal do NOT prove the UI is
// identical (a keyboard appearing without a VC change can leave it
// stable). But two fingerprints that DIFFER reliably prove something
// changed. That asymmetry is exactly what post-tap verification needs:
// if pre == post after a short delay, the tap silently dropped.
//
// The value type lives in AutoCore so it's trivially testable. The
// iOS-specific capture from an AXUIElement root lives in AutoLibiOS as
// an extension.

public struct ViewFingerprint: Equatable {
    public let rootChildCount: Int
    public let topLevelSignature: String

    public init(rootChildCount: Int, topLevelSignature: String) {
        self.rootChildCount = rootChildCount
        self.topLevelSignature = topLevelSignature
    }
}

public extension ViewFingerprint {

    /// Captura desde el snapshot `[[String: Any]]` que devuelve
    /// `DeviceBridge.tree()` — la contraparte compartida (iOS + Android) del
    /// `capture(root: AXUIElement)` de AutoLibiOS, que es iOS-only porque
    /// depende de ApplicationServices. Mismo contrato asimétrico: dos
    /// fingerprints distintos prueban que la UI cambió; iguales no prueban
    /// nada. Mismos límites (primeros `maxChildren` hijos + `maxGrandchildren`
    /// nietos) para que el costo sea O(1) respecto al tamaño del tree.
    /// Usada por el settle tap→type del CommandDispatcher (#159).
    static func capture(tree: [[String: Any]],
                        maxChildren: Int = 6,
                        maxGrandchildren: Int = 1) -> ViewFingerprint {
        var parts: [String] = []
        parts.reserveCapacity(maxChildren * (1 + maxGrandchildren))

        for el in tree.prefix(maxChildren) {
            parts.append(signature(el))
            if let children = el["children"] as? [[String: Any]] {
                for g in children.prefix(maxGrandchildren) {
                    parts.append("·" + signature(g))
                }
            }
        }
        return ViewFingerprint(rootChildCount: tree.count,
                               topLevelSignature: parts.joined(separator: "|"))
    }

    /// role:identifier-o-title:frame — el mismo formato que axSignature en
    /// AutoLibiOS/ViewFingerprint.swift, sobre las claves del dict del tree.
    private static func signature(_ el: [String: Any]) -> String {
        let role = (el["role"] as? String) ?? ""
        let title = (el["title"] as? String) ?? ""
        let ident = (el["identifier"] as? String) ?? ""
        var frame = "0,0,0,0"
        if let f = el["frame"] as? [String: Any] {
            frame = "\(f["x"] ?? 0),\(f["y"] ?? 0),\(f["width"] ?? 0),\(f["height"] ?? 0)"
        }
        return "\(role):\(ident.isEmpty ? title : ident):\(frame)"
    }
}
